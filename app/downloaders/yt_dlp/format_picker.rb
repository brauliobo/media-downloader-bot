module Downloaders
  class YtDlp
    # Picks the best format (or video+audio pair) Telegram plays as is whose estimated size fits the upload limit.
    # Video covers videos and Audio covers audio-only requests and sources, each with its own candidates.
    class FormatPicker
      SAFETY = 0.95

      def self.for(info, audio_only: false, **opts) = (audio_only ? Audio : Video).new(info, **opts)

      def initialize(info, limit_mb:, clip: info.duration, alang: nil, **)
        @info, @alang, @clip = info, alang, clip.to_f
        @budget = limit_mb * 2**20 * SAFETY
        @ratio  = @clip / info.duration.to_f
      end

      # yt-dlp format ids joined with + (nil when nothing fits)
      def selector
        return unless @info.duration.to_f.positive?

        candidates.select { |c| fits?(c) }.max_by { |c| rank(c) }&.map(&:format_id)&.join('+')
      end

      private

      # each candidate is the list of formats that would be downloaded together
      def candidates = raise(NotImplementedError)

      # yt-dlp lists formats worst to best, so the index is the rank
      def formats = @formats ||= Array(@info.formats)
      def rank(candidate) = candidate.map { |f| formats.index(f) }

      # keeps the original audio language first unless another was asked for
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
