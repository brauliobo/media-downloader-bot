require 'fileutils'
require 'tmpdir'

require_relative '../diarizer'
require_relative '../prober'
require_relative '../subtitler'
require_relative '../subtitler/translator'
require_relative '../translator'
require_relative '../tts'
require_relative '../tts/options'
require_relative 'audio'
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
          dir:       workdir
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

        SymMash.new(
          text:        text,
          source_text: sentence.text.to_s.strip,
          source_words: Array(sentence.words).map { |word| SymMash.new(word.to_h) },
          start:       sentence.start.to_f,
          end:         sentence.end.to_f
        )
      end
    end

    def synthesize_timeline(workdir)
      @stl&.update 'dubbing: synthesizing'
      clips          = Array.new(@sentences.size)
      completed      = 0
      progress_mutex = Mutex.new
      on_batch       = lambda do |batch|
        progress_mutex.synchronize do
          completed += batch.size
          @stl&.update "dubbing: synthesizing #{completed}/#{@sentences.size}"
        end
      end
      @sentences.each_index.group_by { |idx| @sentences.fetch(idx).speaker_id }.each do |speaker_id, indices|
        reference = @speaker_references.fetch(speaker_id)
        options   = TTS::Options.for(@opts).merge(reference.tts_options)
        jobs = indices.map do |idx|
          {
            text:     @sentences.fetch(idx).text,
            lang:     target_lang,
            out_path: File.join(workdir, format('sentence-%04d.raw.wav', idx + 1))
          }
        end

        TTS.synthesize_batch(items: jobs, on_batch: on_batch, **options)
        jobs.zip(indices).each do |job, idx|
          fit = File.join(workdir, format('sentence-%04d.fit.wav', idx + 1))
          Audio.normalize(job.fetch(:out_path), fit)
          sentence = @sentences.fetch(idx)
          clips[idx] = Audio::Clip.new(path: fit, start: sentence.start.to_f, end: sentence.end.to_f)
        end
      end

      Audio.render_timeline(clips, File.join(workdir, 'dub.wav'), duration: video_duration)
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
      Subtitler::VTT.build(SymMash.new(segments: @sentences), word_tags: false)
    end

    def source_subtitle_vtt
      Subtitler::VTT.build(@transcript_output || SymMash.new(segments: []), normalize: false, word_tags: false)
    end

    def translated_source_subtitle_vtt
      Subtitler::VTT.translate(source_subtitle_vtt, from: source_lang, to: subtitle_target_lang)
    end

    def bilingual_subtitle_vtt
      segments = @sentences.map do |sentence|
        texts = [sentence.source_text, sentence.text].map { |text| text.to_s.strip }.reject(&:empty?).uniq
        SymMash.new(text: texts.join("\n"), start: sentence.start, end: sentence.end, words: [])
      end
      Subtitler::VTT.build(SymMash.new(segments: segments), normalize: false, word_tags: false)
    end

    def subtitle_target_lang
      @opts.sub_lang.presence || target_lang
    end

    def apply_timeline(clips)
      @sentences.zip(clips).each do |sentence, clip|
        sentence.start = clip.start
        sentence.end   = [clip.end, video_duration].min
      end
      @sentences.select! { |sentence| sentence.start < video_duration }
    end

    def merge_speaker_sentences!
      @sentences = @sentences.each_with_object([]) do |sentence, utterances|
        previous = utterances.last
        if previous && mergeable_utterance?(previous, sentence)
          previous.text         = "#{previous.text} #{sentence.text}".strip
          previous.source_text  = "#{previous.source_text} #{sentence.source_text}".strip
          previous.source_words = Array(previous.source_words) + Array(sentence.source_words)
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
