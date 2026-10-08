module Downloaders
  class YtDlp
    # What tells yt-dlp which format to fetch: the picked one as is (streamed), or the best one to be encoded.
    class FormatArgs
      FASTSTART = 'Merger+ffmpeg_o:-movflags +faststart'.freeze

      def initialize(opts, url)
        @opts, @url = opts, url
      end

      def for(stream) = stream ? streamed(stream) : encoded

      # the picked format as is, merged into an mp4 that starts playing before it is fully downloaded
      def streamed(selector)
        "-f #{Sh.escape(selector)} --merge-output-format mp4 --postprocessor-args #{Sh.escape(FASTSTART)}"
      end

      # the best format, to be encoded later (audio is extracted from it for audio requests)
      def encoded
        "-f #{Sh.escape(best)}#{' -x' if @opts.audio || @opts.onlysrt}"
      end

      private

      def best
        return 'mp3-320' if @opts.audio && @url.include?('bandcamp.com')

        base = (@opts.onlysrt || @opts.audio) ? 'bestaudio' : 'bestvideo+bestaudio'
        al   = @opts.alang
        return "#{base}/best" unless al

        "#{base}[language^=#{al}]/best[language^=#{al}]/#{base}/best"
      end
    end
  end
end
