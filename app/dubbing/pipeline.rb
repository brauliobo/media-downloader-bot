require 'fileutils'
require 'json'

module Dubbing
  class Pipeline
    include Subtitles
    include Timings

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
        transcript = Subtitler.transcribe_vocals(stems.vocals)
        @transcript_output = transcript
        @source_lang = transcript.language
        next @input_path if @source_lang.present? && @source_lang == target_lang
        next @input_path if transcript.sentence_entries.empty?

        @stl&.update 'dubbing: diarizing'
        diarization = Diarizer.diarize(stems.vocals, speakers: @opts.speakers&.to_i)
        Diarizer.assign_speakers!(transcript, diarization.segments, sentence_level: true)

        replace_sentences!(translated_sentences(transcript))
        next @input_path if @sentences.empty?

        Utils::Tmp.dir('dub-', @dir) do |workdir|
          @speaker_references = VoiceReference.extract_by_speaker(
            stems.vocals,
            diarization.segments,
            sentences: @sentences,
            dir:       workdir,
            transcriber: ::VoiceReference::Transcriber.new
          )
          timeline = synthesize_timeline(workdir)
          spoken   = transcribe_spoken_timeline(timeline.path)
          apply_scheduled_timings!(timeline.clips, spoken: spoken)
          @timing_score = timeline.score
          write_timing_score
          prepare_translated_subtitles
          mix_video(timeline.path, stems.non_vocals, workdir)
        end
      end
    end

    private

    def normalize_target_lang
      Language::Code.normalize(@opts.dub_lang || @opts.lang || @opts.slang) || DEFAULT_TARGET_LANG
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
