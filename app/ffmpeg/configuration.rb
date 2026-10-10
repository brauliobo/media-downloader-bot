class FFmpeg
  module Configuration
    extend ActiveSupport::Concern

    class_methods do
      def verify! runner: Sh.method(:run)
        new(runner: runner).verify!
      end

      def pause_encoding format, fdk_aac: nil
        format = format ? format.to_h.transform_keys(&:to_sym) : {}
        codec_name = format[:codec_name].to_s
        return PauseEncoding.new codec: nil, profile: nil, bitrate: nil, sample_format: nil if codec_name.empty?

        encoder = pause_codec codec_name, format, fdk_aac
        return PauseEncoding.new codec: nil, profile: nil, bitrate: nil, sample_format: nil unless encoder

        PauseEncoding.new(
          codec:        encoder,
          profile:      pause_profile(codec_name, format),
          bitrate:      pause_bitrate(codec_name, format, encoder),
          sample_format: pause_sample_format(codec_name, format)
        )
      end

      # The builder a caller handed in, the one its factory makes, or a fresh one.
      def resolve(ffmpeg = nil, ffmpeg_factory = nil) = ffmpeg || ffmpeg_factory&.call || new

      def transcription_binary
        ENV.fetch 'TRANSCRIBE_CPP_FFMPEG', BINARIES.first
      end

      def fdk_aac_available? ffmpeg: BINARIES[0], runner: Sh.method(:run)
        @fdk_aac_capabilities ||= {}
        key = [ffmpeg, runner]
        CAPABILITY_MUTEX.synchronize do
          return @fdk_aac_capabilities[key] if @fdk_aac_capabilities.key? key

          detector = new ffmpeg: ffmpeg, runner: runner
          @fdk_aac_capabilities[key] = detector.encoder_available? 'libfdk_aac'
        end
      end

    private

      def pause_codec codec_name, format, fdk_aac
        return {'mp3' => 'libmp3lame', 'opus' => 'libopus', 'vorbis' => 'libvorbis'}[codec_name] if
          %w[mp3 opus vorbis].include? codec_name

        return codec_name unless codec_name == 'aac'

        fdk_aac = fdk_aac_available? if fdk_aac.nil?
        return if !fdk_aac && format[:profile].to_s.match?(/HE-AAC/i)

        fdk_aac ? AUDIO_ENCODERS.fetch(:aac).fetch(:codec_fdk) : AUDIO_ENCODERS.fetch(:aac).fetch(:codec)
      end

      def pause_profile codec_name, format
        return unless codec_name == 'aac'

        {
          'LC'       => 'aac_low',
          'HE-AAC'   => 'aac_he',
          'HE-AACV2' => 'aac_he_v2',
        }[format[:profile].to_s.upcase]
      end

      def pause_bitrate codec_name, format, encoder
        bit_rate = format[:bit_rate].to_i
        return unless bit_rate.positive?
        return if codec_name.start_with?('pcm_') || codec_name == 'flac'

        bit_rate if encoder
      end

      def pause_sample_format codec_name, format
        return unless codec_name.start_with? 'pcm_'

        format[:sample_fmt].to_s unless format[:sample_fmt].to_s.empty?
      end
    end

    def initialize ffmpeg: BINARIES[0], ffprobe: BINARIES[1], runner: Sh.method(:run),
                    threads: ENV['THREADS'] || 16, profile: :encode, fdk_aac: false
      @ffmpeg          = ffmpeg
      @ffprobe         = ffprobe
      @runner          = runner
      @default_threads = threads
      @profile         = profile.to_sym
      @fdk_aac         = fdk_aac
      PROFILES.fetch @profile
      reset!
    end

    def verify!
      one_shot do
        [@ffmpeg, @ffprobe].each do |binary|
          name = File.basename binary
          stdout, stderr, status = @runner.call [binary, '-version']
          output = "#{stdout}\n#{stderr}"
          raise "#{name} is required" unless status.success?

          version = output[/\A#{Regexp.escape name} version n?(\d+(?:\.\d+)+)/, 1]
          raise "unable to determine #{name} version" unless version
          next if Gem::Version.new(version) >= MIN_VERSION

          raise "#{name} #{MIN_VERSION} or newer is required; found #{version}"
        rescue Errno::ENOENT
          raise "#{name} is required"
        end
      end
    end
  end
end
