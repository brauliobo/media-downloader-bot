module Downloaders
  class YtDlp
    # Decides whether an entry is streamed (uploaded as downloaded) and, if so, which yt-dlp format to fetch.
    # It is nil when streaming is off for the request or no format fits the limit; the entry is then encoded.
    class StreamSelector
      def initialize(info, opts:, audio_only:, max_res:)
        @info, @opts, @audio_only, @max_res = info, opts, audio_only, max_res
      end

      def selector
        return unless Streaming.enabled?(@opts)

        FormatPicker.for(
          @info, audio_only: @audio_only, limit_mb: Zipper.size_mb_limit, max_res: @max_res, clip: clip_seconds, alang: @opts.alang
        ).selector
      end

      private

      # a requested section (ss, to, t) is cut while downloading, so only its length counts
      def clip_seconds
        return @info.duration unless Utils::Duration.cut?(@opts)

        cut = Utils::Duration.from_opts(@opts)
        (cut.finish || @info.duration) - cut.start
      end
    end
  end
end
