require 'fileutils'
require 'tmpdir'

require_relative '../diarizer'
require_relative '../prober'
require_relative '../subtitler'
require_relative '../subtitler/translator'
require_relative '../translator'
require_relative 'audio'
require_relative 'speech_synthesizer'
require_relative 'voice_reference'

module Dubbing
  class Pipeline
    DEFAULT_TARGET_LANG = 'pt'.freeze
    MAX_UTTERANCE_GAP   = 0.25
    MAX_UTTERANCE_SPAN  = 10.0

    attr_reader :source_lang, :target_lang, :speaker_references, :sentences

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
      @stl&.update 'dubbing: transcribing'
      transcript = Subtitler.transcribe(@input_path)
      @transcript_output = transcript.output
      @source_lang = Subtitler.normalize_lang(transcript.lang)
      return @input_path if @source_lang.present? && @source_lang == target_lang

      @stl&.update 'dubbing: translating'
      @sentences = translated_sentences(transcript.output)
      return @input_path if @sentences.empty?

      Dir.mktmpdir('dub-', @dir) do |workdir|
        @stl&.update 'dubbing: diarizing'
        diarization = Diarizer.diarize(@input_path, speakers: @opts.speakers&.to_i)
        Diarizer.assign_speakers!(@sentences, diarization.segments)
        @speaker_references = VoiceReference.extract_by_speaker(
          @input_path,
          diarization.segments,
          sentences: @sentences,
          dir:       workdir,
          transcriber: ::VoiceReference::Transcriber.new
        )
        merge_speaker_sentences!
        timeline = synthesize_timeline(workdir)
        apply_timeline(timeline.clips)
        prepare_translated_subtitles
        mix_video(timeline.path, workdir)
      end
    end

    private

    def normalize_target_lang
      Subtitler.normalize_lang(@opts.slang || @opts.lang) || DEFAULT_TARGET_LANG
    end

    def translated_sentences(verbose_json)
      source = SymMash.new(verbose_json)
      sentences = Subtitler::Translator.sentences_for(Array(source.segments))
      texts = sentences.map { |sentence| sentence.text.to_s }
      durations = sentences.map { |sentence| sentence.end.to_f - sentence.start.to_f }
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
          source_text:  sentence.text.to_s.strip,
          source_words: source_words,
          start:        sentence.start.to_f,
          end:          sentence.end.to_f,
          words:        target_words
        )
      end
    end

    def translated_word_timings(sentence, text)
      source_words = Array(sentence.words).map { |word| SymMash.new(word.to_h) }
      target_words = source_words.map { |word| SymMash.new(word.to_h) }
      return [source_words, target_words] if target_words.empty?

      timed = SymMash.new(words: target_words)
      Subtitler::Translator.assign_tokens_to_words!(timed, Subtitler::Translator.tokenize_text(text))
      [source_words, timed.words]
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
        @opts.sub_vtt  = subtitle_target_lang == target_lang ? translated_subtitle_vtt : translated_source_subtitle_vtt
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

    def translated_source_subtitle_vtt
      Subtitler::VTT.translate(source_subtitle_vtt, from: source_lang, to: subtitle_target_lang)
    end

    def bilingual_subtitle_vtt
      segments = @sentences.map do |sentence|
        texts = [sentence.source_text, sentence.text].map { |text| text.to_s.strip }.reject(&:empty?).uniq
        SymMash.new(text: texts.join("\n"), start: sentence.start, end: sentence.end, words: [])
      end
      build_subtitle_vtt(SymMash.new(segments: segments), normalize: false)
    end

    def build_subtitle_vtt(data, normalize: true)
      Subtitler::VTT.build(data, normalize: normalize, word_tags: !@opts.nowords)
    end

    def subtitle_target_lang
      @opts.sub_lang.presence || target_lang
    end

    def apply_timeline(clips)
      @sentences.zip(clips).each do |sentence, clip|
        source_start = sentence.start.to_f
        source_end   = sentence.end.to_f
        target_start = clip.start.to_f
        target_end   = [clip.end.to_f, video_duration].min
        retime_words!(sentence.words, source_start, source_end, target_start, target_end)
        sentence.start = target_start
        sentence.end   = target_end
      end
      @sentences.select! { |sentence| sentence.start < video_duration }
    end

    def retime_words!(words, source_start, source_end, target_start, target_end)
      source_duration = source_end - source_start
      target_duration = target_end - target_start
      return unless source_duration.positive? && target_duration.positive?

      scale = target_duration / source_duration
      Array(words).each do |word|
        word.start = target_start + (word.start.to_f - source_start) * scale
        word.end   = target_start + (word.end.to_f - source_start) * scale
      end
    end

    def merge_speaker_sentences!
      @sentences = @sentences.each_with_object([]) do |sentence, utterances|
        previous = utterances.last
        if previous && mergeable_utterance?(previous, sentence)
          previous.text         = "#{previous.text} #{sentence.text}".strip
          previous.source_text  = "#{previous.source_text} #{sentence.source_text}".strip
          previous.source_words = Array(previous.source_words) + Array(sentence.source_words)
          previous.words        = Array(previous.words) + Array(sentence.words)
          previous.end          = sentence.end
        else
          utterances << sentence
        end
      end
    end

    def mergeable_utterance?(previous, sentence)
      gap  = sentence.start.to_f - previous.end.to_f
      span = sentence.end.to_f - previous.start.to_f
      previous.speaker_id == sentence.speaker_id && gap.between?(0, MAX_UTTERANCE_GAP) && span <= MAX_UTTERANCE_SPAN
    end

    def mix_video(dub_audio, workdir)
      @stl&.update 'dubbing: mixing'
      output = File.join(workdir, 'dubbed-source.mp4')
      Audio.replace_video_audio(@input_path, dub_audio, output, duration: video_duration)

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
