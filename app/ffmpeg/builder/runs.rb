class FFmpeg
  module Builder
    # Builders and probes that run to completion on their own, leaving this one as it was.
    module Runs
      private

      def fresh profile: @profile
        self.class.new(
          ffmpeg:  @ffmpeg,
          ffprobe: @ffprobe,
          runner:  @runner,
          threads: @default_threads,
          profile: profile,
          fdk_aac: @fdk_aac
        )
      end

      def one_shot
        reset!
        yield
      ensure
        reset!
      end

      def run_one_shot profile: @profile, label:
        one_shot do
          builder = fresh profile: profile
          yield builder
          builder.run! label: label
        end
      end

      def run_probe arguments, label:
        stdout, stderr, status = @runner.call [@ffprobe, *arguments]
        Sh.assert_success! label, stderr, status: status
        stdout
      end
    end
  end
end
