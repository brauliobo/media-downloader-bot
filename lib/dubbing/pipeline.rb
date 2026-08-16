require 'fileutils'
require 'json'
require 'tmpdir'

require_relative '../diarizer'
require_relative '../prober'
require_relative '../subtitler'
require_relative '../subtitler/translator'
require_relative '../translator'
require_relative '../voice_separator'
require_relative 'audio'
require_relative 'speech_synthesizer'
require_relative 'voice_reference'

module Dubbing
  class Pipeline
    DEFAULT_TARGET_LANG = 'pt'.freeze
    attr_reader :source_lang, :target_lang, :speaker_references, :sentences, :timing_score

    def self.apply(input_path, dir:, opts:, stl: nil, probe: nil)
      new(input_path, dir: dir, opts: opts, stl: stl, probe: probe).apply
    end

    def initialize(input_path, dir:, opts:, stl: nil, probe: nil)
      @input_path  = input_path
      @dir         = dir
      @opts        = opts || SymMash.new
      @stl         = stl
      @probe       = probe
      @target_lang = normalize_target_lang
      @sentences   = []
    end

    def apply
      @stl&.update 'dubbing: separating voice'
      VoiceSeparator.with_stems(@input_path, dir: @dir) do |stems|
        @stl&.update 'dubbing: transcribing'
        transcript = Subtitler.transcribe(stems.vocals, separate_voice: false)
        @transcript_output = transcript
        @source_lang = transcript.language
        next @input_path if @source_lang.present? && @source_lang == target_lang

        @stl&.update 'dubbing: translating'
        @sentences = translated_sentences(transcript)
        next @input_path if @sentences.empty?

        Dir.mktmpdir('dub-', @dir) do |workdir|
          @stl&.update 'dubbing: diarizing'
          diarization = Diarizer.diarize(stems.vocals, speakers: @opts.speakers&.to_i)
          Diarizer.assign_speakers!(@sentences, diarization.segments)
          @speaker_references = VoiceReference.extract_by_speaker(
            stems.vocals,
            diarization.segments,
            sentences: @sentences,
            dir:       workdir,
            transcriber: ::VoiceReference::Transcriber.new(separate_voice: false)
          )
          timeline = synthesize_timeline(workdir)
          apply_scheduled_timings!(timeline.clips)
          @timing_score = timeline.score
          write_timing_score
          prepare_translated_subtitles
          mix_video(timeline.path, stems.non_vocals, workdir)
        end
      end
    end

    private

    def normalize_target_lang
      Subtitler.normalize_lang(@opts.dub_lang || @opts.slang || @opts.lang) || DEFAULT_TARGET_LANG
    end

    def translated_sentences(subtitle)
      sentences = Subtitler::Translator.sentences_for(subtitle)
      texts     = sentences.map(&:text)
      durations = sentences.map { |sentence| sentence.finish - sentence.start }
      translations = if ::Translator.respond_to?(:translate_for_dubbing)
        Array(::Translator.translate_for_dubbing(texts, from: source_lang, to: target_lang, durations: durations))
      else
        Array(::Translator.translate(texts, from: source_lang, to: target_lang))
      end

      sentences.zip(translations).filter_map do |sentence, translated|
        text = Subtitler::Translator.clean_translation(translated)
        next if text.empty?

        source_words, target_words = translated_word_timings(sentence, text)
        SymMash.new(
          text:         text,
          source_text:  sentence.text.strip,
          source_words: source_words,
          start:        sentence.start.to_f,
          end:          sentence.finish,
          words:        target_words
        )
      end
    end

    def translated_word_timings(sentence, text)
      source_words = sentence.words.map { |word| SymMash.new(word.to_whisper_hash) }
      return [source_words, []] if source_words.empty?

      timed = sentence.deep_copy
      Subtitler::Translator.assign_tokens_to_words!(timed, Subtitler::Translator.tokenize_text(text))
      target_words = timed.words.map { |word| SymMash.new(word.to_whisper_hash) }
      [source_words, target_words]
    end

    def synthesize_timeline(workdir)
      SpeechSynthesizer.new(
        sentences:       @sentences,
        references:      @speaker_references,
        opts:            @opts,
        target_lang:     target_lang,
        workdir:         workdir,
        video_duration:  video_duration,
        stl:             @stl
      ).render
    end

    def apply_scheduled_timings!(clips)
      unless @sentences.size == clips.size
        raise "dubbed timeline clip count mismatch: expected #{@sentences.size}, got #{clips.size}"
      end

      @sentences = @sentences.zip(clips).filter_map do |sentence, clip|
        source_start    = sentence.start.to_f
        source_end      = sentence.end.to_f
        target_start    = clip.start.to_f
        target_end      = clip.end.to_f
        source_duration = source_end - source_start
        target_duration = target_end - target_start
        next unless target_duration.positive?

        if source_duration.positive?
          scale = target_duration / source_duration
          Array(sentence.words).each do |word|
            word.start = target_start + (word.start.to_f - source_start) * scale
            word.end   = target_start + (word.end.to_f - source_start) * scale
          end
        end

        sentence.start = target_start
        sentence.end   = target_end
        sentence
      end
    end

    def prepare_translated_subtitles
      mode = @opts.sub_mode.to_s
      return if mode == 'none'
      return unless @opts.gensubs || mode.present?

      case mode
      when 'source'
        @opts.sub_vtt  = source_subtitle_vtt
        @opts.sub_lang = source_lang
      when 'both'
        @opts.sub_vtt  = bilingual_subtitle_vtt
        @opts.sub_lang = 'mul'
      when 'language'
        @opts.sub_vtt  = subtitle_target_lang == target_lang ? translated_subtitle_vtt : alternate_translated_subtitle_vtt
        @opts.sub_lang = subtitle_target_lang
      else
        @opts.sub_vtt  = translated_subtitle_vtt
        @opts.sub_lang = target_lang
      end
    end

    def translated_subtitle_vtt
      build_subtitle_vtt(SymMash.new(segments: @sentences))
    end

    def source_subtitle_vtt
      build_subtitle_vtt(@transcript_output || SymMash.new(segments: []), normalize: false)
    end

    def alternate_translated_subtitle_vtt
      scheduled = SymMash.new(segments: @sentences.deep_dup)
      translated = Subtitler::Translator.translate(
        subtitle_model(scheduled),
        from:           target_lang,
        to:             subtitle_target_lang,
        merge_adjacent: false
      )
      build_subtitle_vtt(translated, normalize: false)
    end

    def subtitle_model(data)
      Subtitler::Subtitle.from_whisper_verbose_json(JSON.parse(JSON.generate(data)))
    end

    def bilingual_subtitle_vtt
      segments = @sentences.map do |sentence|
        texts = [sentence.source_text, sentence.text].map { |text| text.to_s.strip }.reject(&:empty?).uniq
        SymMash.new(text: texts.join("\n"), start: sentence.start, end: sentence.end, words: [])
      end
      build_subtitle_vtt(SymMash.new(segments: segments), normalize: false)
    end

    def build_subtitle_vtt(data, normalize: true)
      subtitle = data.is_a?(Subtitler::Subtitle) ? data : subtitle_model(data)
      Subtitler::VTT.build(subtitle, normalize: normalize, word_tags: !@opts.nowords)
    end

    def subtitle_target_lang
      @opts.sub_lang.presence || target_lang
    end

    def write_timing_score
      return unless @opts.dubscore.present?

      File.write(File.expand_path(@opts.dubscore.to_s), JSON.pretty_generate(timing_score))
    end

    def mix_video(dub_audio, non_vocals, workdir)
      @stl&.update 'dubbing: mixing'
      output = File.join(workdir, 'dubbed-source.mp4')
      Audio.replace_video_audio(
        @input_path, dub_audio, non_vocals, output, duration: video_duration
      )

      final = File.join(@dir, "dubbed-#{File.basename(@input_path, File.extname(@input_path))}.mp4")
      FileUtils.cp(output, final)
      final
    end

    def video_duration
      @video_duration ||= begin
        source = @probe || Prober.for(@input_path)
        source.format.duration.to_f
      end
    end
  end
end
