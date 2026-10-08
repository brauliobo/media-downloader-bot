module Downloaders
  class YtDlp
    # Picks the best mp4-compatible format (or video+audio pair) whose estimated size fits the upload limit.
    class FormatPicker
      SAFETY      = 0.95
      VIDEO_CODEC = /\A(avc1|h264)/
      AUDIO_CODEC = /\Amp4a/

      def initialize(info, limit_mb:, max_res:, clip: info.duration, alang: nil)
        @info, @max_res, @alang, @clip = info, max_res, alang, clip.to_f
        @budget = limit_mb * 2**20 * SAFETY
        @ratio  = @clip / info.duration.to_f
      end

      def selector
        return unless @info.duration.to_f.positive?

        candidates.select { |c| fits?(c) }.max_by { |c| c.map { |f| formats.index(f) } }&.map(&:format_id)&.join('+')
      end

      private

      # yt-dlp lists formats worst to best, so the index is the rank (and keeps the original audio language first).
      def formats = @formats ||= Array(@info.formats)

      def candidates = combined.map { |f| [f] } + videos.product(audios)

      def combined = formats.select { |f| video?(f) && audio?(f) }
      def videos   = formats.select { |f| video?(f) && f.acodec == 'none' }
      def audios   = preferred_language(formats.select { |f| audio?(f) && f.vcodec == 'none' })

      def video?(format) = format.ext == 'mp4' && format.vcodec.to_s.match?(VIDEO_CODEC) && [format.width, format.height].compact.min.to_i <= @max_res
      def audio?(format) = format.ext.in?(%w[mp4 m4a]) && format.acodec.to_s.match?(AUDIO_CODEC)

      def preferred_language(audios)
        matching = audios.select { |f| f.language.to_s.start_with?(@alang.to_s) } if @alang
        matching.presence || audios
      end

      def fits?(candidate)
        sizes = candidate.map { |f| size(f) }
        sizes.all? && sizes.sum <= @budget
      end

      def size(format)
        bytes = format.filesize || format.filesize_approx
        bytes ? bytes * @ratio : (format.tbr && format.tbr * 125 * @clip)
      end
    end
  end
end
