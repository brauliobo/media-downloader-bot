require 'fileutils'
require 'tmpdir'

require_relative '../subtitler'
require_relative '../subtitler/translator'
require_relative '../translator'
require_relative '../tts'
require_relative '../tts/options'
require_relative '../utils/sh'
require_relative '../zipper'
require_relative 'voice_reference'

module Dubbing
  class Pipeline
    DEFAULT_TARGET_LANG = 'pt'.freeze

    attr_reader :source_lang, :target_lang, :speaker_wav, :sentences

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
      @source_lang = Subtitler.normalize_lang(transcript.lang)
      return @input_path if @source_lang.present? && @source_lang == target_lang

      @sentences = translated_sentences(transcript.output)
      return @input_path if @sentences.empty?

      Dir.mktmpdir('dub-', @dir) do |workdir|
        @speaker_wav = VoiceReference.extract(@input_path, @sentences, dir: workdir)
        dub_audio = synthesize_timeline(workdir)
        mix_video(dub_audio, workdir)
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
      translations = Array(::Translator.translate(texts, from: source_lang, to: target_lang))

      sentences.zip(translations).filter_map do |sentence, translated|
        text = translated.to_s.strip
        next if text.empty?

        SymMash.new(
          text:  text,
          start: sentence.start.to_f,
          end:   sentence.end.to_f
        )
      end
    end

    def synthesize_timeline(workdir)
      @stl&.update 'dubbing: synthesizing'
      clips = @sentences.map.with_index do |sentence, idx|
        synthesize_sentence(sentence, idx + 1, workdir)
      end

      assemble_timeline(clips, File.join(workdir, 'dub.wav'))
    end

    def synthesize_sentence(sentence, idx, workdir)
      raw = File.join(workdir, format('sentence-%04d.raw.wav', idx))
      fit = File.join(workdir, format('sentence-%04d.fit.wav', idx))
      options = TTS::Options.for(@opts, speaker_wav: @speaker_wav)

      TTS.synthesize(text: sentence.text, lang: target_lang, out_path: raw, **options)
      fit_clip(raw, fit, sentence_duration(sentence))
      SymMash.new(path: fit, start: sentence.start.to_f)
    end

    def sentence_duration(sentence)
      [sentence.end.to_f - sentence.start.to_f, 0.1].max
    end

    def fit_clip(input, output, duration)
      speed = clip_speed(input, duration)
      filters = []
      filters << "atempo=#{speed}" if speed > 1.01
      filters << 'apad'
      filters << format('atrim=0:%<duration>.3f', duration: duration)

      cmd = "#{Zipper::FFMPEG} -i #{Sh.escape(input)} -af #{Sh.escape(filters.join(','))} " \
            "-ac 1 -ar 48000 #{Sh.escape(output)}"
      _, stderr, status = Sh.run cmd
      raise "dub sentence fit failed: #{stderr}" unless status.success? && File.exist?(output)

      output
    end

    def clip_speed(path, slot_duration)
      raw_duration = audio_duration(path)
      return 1.0 if raw_duration <= slot_duration

      [raw_duration / slot_duration, 100.0].min
    end

    def audio_duration(path)
      Prober.for(path).format.duration.to_f
    rescue
      0.0
    end

    def assemble_timeline(clips, output)
      return create_silence(output, video_duration) if clips.empty?

      inputs = clips.map { |clip| "-i #{Sh.escape(clip.path)}" }.join(' ')
      chains = clips.map.with_index do |clip, idx|
        delay = (clip.start.to_f * 1000).round
        "[#{idx}:a]adelay=#{delay}:all=1[a#{idx}]"
      end
      mix_inputs = clips.each_index.map { |idx| "[a#{idx}]" }.join
      filter = "#{chains.join(';')};#{mix_inputs}amix=inputs=#{clips.size}:normalize=0,atrim=0:#{video_duration}"
      cmd = "#{Zipper::FFMPEG} #{inputs} -filter_complex #{Sh.escape(filter)} -ac 1 -ar 48000 #{Sh.escape(output)}"
      _, stderr, status = Sh.run cmd
      raise "dub timeline failed: #{stderr}" unless status.success? && File.exist?(output)

      output
    end

    def create_silence(output, duration)
      cmd = "#{Zipper::FFMPEG} -f lavfi -i anullsrc=channel_layout=mono:sample_rate=48000 " \
            "-t #{duration.to_f} #{Sh.escape(output)}"
      _, stderr, status = Sh.run cmd
      raise "dub silence failed: #{stderr}" unless status.success? && File.exist?(output)

      output
    end

    def mix_video(dub_audio, workdir)
      @stl&.update 'dubbing: mixing'
      output = File.join(workdir, 'dubbed-source.mp4')
      duration = video_duration
      cmd = if source_audio?
        sidechain = '[0:a][1:a]sidechaincompress=threshold=0.02:ratio=8:attack=20:release=500[ducked]'
        filter = "#{sidechain};[ducked][1:a]amix=inputs=2:duration=first:normalize=0[aout]"
        "#{Zipper::FFMPEG} -i #{Sh.escape(@input_path)} -i #{Sh.escape(dub_audio)} " \
          "-filter_complex #{Sh.escape(filter)} -map 0:v:0 -map '[aout]' -t #{duration} " \
          "-c:v copy -c:a aac -b:a 128k #{Sh.escape(output)}"
      else
        "#{Zipper::FFMPEG} -i #{Sh.escape(@input_path)} -i #{Sh.escape(dub_audio)} " \
          "-map 0:v:0 -map 1:a:0 -t #{duration} -c:v copy -c:a aac -b:a 128k #{Sh.escape(output)}"
      end
      _, stderr, status = Sh.run cmd
      raise "dub mix failed: #{stderr}" unless status.success? && File.exist?(output)

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

    def source_audio?
      source = @probe || Prober.for(@input_path)
      Array(source.streams).any? { |stream| stream.codec_type == 'audio' }
    end
  end
end
