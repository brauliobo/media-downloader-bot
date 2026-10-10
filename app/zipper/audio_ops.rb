class Zipper
  # Operations on audio files on their own: joined, converted for a model, floored or sped up.
  module AudioOps
    # What the speech models take: 16 kHz mono.
    SPEECH = { sample_rate: 16_000, channels: 1 }.freeze

    module_function

    def concat(inputs, outfile, stl: nil, ffmpeg: nil, ffmpeg_factory: nil)
      return FileUtils.cp inputs.first, outfile if inputs.size == 1

      builder = FFmpeg.resolve(ffmpeg, ffmpeg_factory)
      signatures = inputs.map { |input| Prober.audio_signature input, ffmpeg: builder }
      Utils::Tmp.dir('concat-') do |dir|
        listfile = File.join dir, 'concat.txt'
        File.write listfile, inputs.map { |path| Utils::Safety.concat_manifest_path path }.join("\n")

        copy = copy_safe? signatures
        sample_rate = signatures.map { |signature| signature[:sample_rate].to_i }.max
        arguments = {
          inputs: copy ? listfile : inputs,
          output: outfile,
          copy:   copy,
          label:  'FFmpeg concat failed',
        }
        arguments[:sample_rate] = sample_rate if !copy && sample_rate.positive?

        begin
          builder.concat_audio(**arguments)
        rescue Sh::Error
          raise 'FFmpeg concat failed'
        end
      end

      outfile
    end

    def copy_safe?(signatures) = signatures.none?(&:empty?) && signatures.uniq.one?

    def add_floor!(wav_path, amplitude:, loudness_lufs:, sample_rate: 22_050, ffmpeg: nil, ffmpeg_factory: nil)
      output = sibling(wav_path, 'audio_floor')
      FFmpeg.resolve(ffmpeg, ffmpeg_factory).add_audio_floor(
        input: wav_path, output: output, amplitude: amplitude, loudness_lufs: loudness_lufs,
        sample_rate: sample_rate, label: 'Failed to add audiobook audio floor'
      )
      replace(wav_path, output)
    end

    def speed!(wav_path, speed, ffmpeg: nil, ffmpeg_factory: nil)
      speed = speed.to_f
      return wav_path unless speed.positive? && speed != 1

      output = sibling(wav_path, 'speed')
      FFmpeg.resolve(ffmpeg, ffmpeg_factory).speed_audio(
        input: wav_path, output: output, filter: FFmpeg.speech_speed_filter(speed), label: 'Failed to apply audio speed'
      )
      replace(wav_path, output)
    end

    def with_wav(path, sample_rate: nil, channels: nil, ffmpeg: nil, ffmpeg_factory: nil, &block)
      options = { sample_rate: sample_rate, channels: channels, ffmpeg: ffmpeg, ffmpeg_factory: ffmpeg_factory }.compact
      wav = to_wav(path, **options)
      File.open(wav, &block)
    ensure
      File.unlink wav if wav && File.exist?(wav)
    end

    def with_speech_wav(path, **options, &block) = with_wav(path, **SPEECH, **options, &block)

    def with_copy(path, ffmpeg: nil, ffmpeg_factory: nil, &block)
      audio = copy(path, ffmpeg: ffmpeg, ffmpeg_factory: ffmpeg_factory)
      File.open(audio, &block)
    ensure
      File.unlink audio if audio && File.exist?(audio)
    end

    def to_wav(path, sample_rate: nil, channels: nil, ffmpeg: nil, ffmpeg_factory: nil)
      wav = temp_audio('.wav')
      converting do
        FFmpeg.resolve(ffmpeg, ffmpeg_factory).audio_to_wav(
          input: path, output: wav, sample_rate: sample_rate, channels: channels, label: 'ffmpeg failed'
        )
      end
      wav
    end

    def copy(path, ffmpeg: nil, ffmpeg_factory: nil)
      audio = temp_audio('.mka')
      converting { FFmpeg.resolve(ffmpeg, ffmpeg_factory).extract_copy_audio(input: path, output: audio, label: 'ffmpeg failed') }
      audio
    end

    def temp_audio(extension) = File.join(Dir.pwd, "audio-#{SecureRandom.hex 6}#{extension}")

    def sibling(path, prefix) = File.join(File.dirname(path), "#{prefix}_#{SecureRandom.hex 4}.wav")

    def replace(path, output)
      FileUtils.mv output, path, force: true
      path
    end

    def converting
      yield
    rescue Sh::Error
      raise 'ffmpeg failed'
    end
  end
end
