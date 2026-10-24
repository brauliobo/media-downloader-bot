module Downloaders
  class YtDlp
    # What tells yt-dlp which format to fetch: the picked one as is (streamed), or the best one to be encoded.
    class FormatArgs
      FASTSTART = 'Merger+ffmpeg_o:-movflags +faststart'.freeze

      def initialize(opts, site)
        @opts, @site = opts, site
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
        return @site.audio_format if @opts.audio && @site.audio_format

        base = (@opts.onlysrt || @opts.audio) ? 'bestaudio' : "#{best_video}+bestaudio"
        al   = @opts.alang
        return "#{base}/best" unless al

        "#{base}[language^=#{al}]/best[language^=#{al}]/#{base}/best"
      end

      def best_video = "bestvideo#{"[format_note!=#{@site.skipped_note}]" if @site.skipped_note}"
    end
  end
end
