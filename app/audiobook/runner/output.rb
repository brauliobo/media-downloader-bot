module Audiobook
  class Runner
    # The finished file: the audio floor, the encoding, and silence for a book with nothing to read.
    module Output
      private

      def add_audio_floor!(wav_path)
        amplitude = @opts&.audio_floor_amplitude.to_f
        return wav_path unless amplitude.positive?

        Zipper::AudioOps.add_floor!(
          wav_path,
          amplitude: amplitude,
          loudness_lufs: @opts&.audio_loudness_lufs.to_f,
          sample_rate: AudioFiles.sample_rate
        )
      end

      def create_silent_audiobook(out_audio)
        @stl&.update 'No text found anywhere - creating silent audio file'

        final_audio = nil
        Utils::Tmp.dir('audiobook-silent-') do |dir|
          silent_wav = create_silent_wav(dir)
          final_audio = encode_audio_file(silent_wav, out_audio) if File.exist?(silent_wav)
        end

        @stl&.update 'Silent audiobook created (no text found)'
        final_audio
      end

      def create_silent_wav(dir)
        silent_wav = File.join(dir, 'silent.wav')
        AudioFiles.silence(silent_wav, Pauses::EMPTY_BOOK)
      end

      def encode_audio_file(input_wav, out_audio)
        zip_opts = SymMash.new(@opts || {})
        zip_opts.delete(:speed)
        # Pick format based on requested extension; default to opus
        requested_ext = File.extname(out_audio.to_s).downcase
        case requested_ext
        when '.m4a', '.aac'
          zip_opts.format = Zipper::Types.audio.aac
        when '.mp3'
          zip_opts.format = Zipper::Types.audio.mp3
        else
          zip_opts.format = Zipper::Types.audio.opus
        end
        zip_opts.bitrate ||= 32
        zip_opts.speech_cleanup = true
        target = out_audio.to_s
        zip_opts.skip_metamark = true
        Zipper.zip_audio(input_wav, target, opts: zip_opts)
        target
      end
    end
  end
end
