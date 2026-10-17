class FFmpeg
  module Operations
    # Joining, generating and reshaping audio files.
    module Audio
      # With copy enabled, inputs is the concat demuxer manifest path. Otherwise it
      # is an ordered collection of media paths joined by the concat filter.
      def concat_audio inputs:, output:, copy:, sample_rate: nil, label:
        run_one_shot label: label do |builder|
          if copy
            manifest = inputs.respond_to?(:to_path) ? inputs.to_path : inputs
            unless manifest.is_a? String
              raise ArgumentError, 'copy concat requires a manifest path'
            end

            builder.input manifest, format: :concat, safe: false
            builder.copy
          else
            inputs.each { |input| builder.input input }
            labels = inputs.each_index.map { |index| "[#{index}:a]" }.join
            filter = "#{labels}concat=n=#{inputs.size}:v=0:a=1"
            filter << ",aresample=#{sample_rate.to_i}" if sample_rate
            filter << '[a]'
            builder.set_complex_filter filter
            builder.map_filter :a
          end
          builder.output output
        end
      end

      def create_silence output:, duration:, label:, source: nil, source_sample_rate: nil,
                         filter: nil, sample_rate: nil, channels: nil, channel_layout: nil,
                         codec: nil, codec_profile: nil, bitrate: nil, sample_format: nil,
                         amplitude: nil
        if source.nil?
          if amplitude && amplitude.to_f.positive?
            source = FFmpeg.noise_source amplitude: amplitude,
                                         sample_rate: source_sample_rate || sample_rate || 48_000
            filter ||= FFmpeg.lowpass_filter 6000
          else
            source = FFmpeg.silence_source sample_rate: source_sample_rate || sample_rate || 48_000,
                                             channel_layout: channel_layout || :mono
          end
        end

        run_one_shot label: label do |builder|
          builder.input source, format: :lavfi
          builder.add_filter filter, stream: :audio if filter
          builder.duration duration
          builder.sample_rate sample_rate if sample_rate
          builder.channels channels if channels
          builder.channel_layout channel_layout if channel_layout
          builder.codec codec, stream: :audio if codec
          builder.codec_profile codec_profile, stream: :audio if codec_profile
          builder.bitrate bitrate, stream: :audio, unit: :bit if bitrate
          builder.sample_format sample_format, stream: :audio if sample_format
          builder.output output
        end
      end

      def add_audio_floor input:, output:, sample_rate:, label:, source: nil, filter: nil,
                           amplitude: nil, loudness_lufs: nil
        source ||= FFmpeg.audio_floor_source amplitude: amplitude, sample_rate: sample_rate
        filter ||= FFmpeg.audio_floor_filter loudness_lufs: loudness_lufs

        run_one_shot label: label do |builder|
          builder.input input
          builder.input source, format: :lavfi
          builder.set_complex_filter filter
          audio_format(builder, channels: 1, sample_rate:)
          builder.output output
        end
      end

      # Re-encodes the audio, through the filter if any (a speed asks for the speech one), as 16-bit PCM unless told otherwise.
      def reencode_audio input:, output:, label:, filter: nil, speed: nil, codec: 'pcm_s16le', bitrate: nil
        filter ||= FFmpeg.speech_speed_filter speed if speed

        run_one_shot label: label do |builder|
          builder.input input
          builder.set_filter filter, stream: :audio if filter
          builder.codec codec, stream: :audio
          builder.bitrate bitrate, stream: :audio, unit: :bit if bitrate
          builder.output output
        end
      end

      def audio_to_wav input:, output:, sample_rate: nil, channels: nil, label:
        run_one_shot label: label do |builder|
          builder.input input
          builder.channels channels if channels
          builder.sample_rate sample_rate if sample_rate
          builder.output output
        end
      end
    end
  end
end
