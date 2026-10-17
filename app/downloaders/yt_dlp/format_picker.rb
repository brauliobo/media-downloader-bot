module Downloaders
  class YtDlp
    # Picks the best format (or video+audio pair) whose streams Telegram plays as they are and whose estimated size fits the limit.
    # Only the codecs matter: yt-dlp merges the pair into an mp4 and the processor rewraps a lone file, so the container is free.
    # A codec the extractor does not report (nil) is given the benefit of the doubt; the downloaded file is probed before it is uploaded.
    # Without a limit (nil limit_mb) the best one is picked whatever its size. An audio-only pick takes no bitrate cap: there is
    # no picture to leave the size budget to.
    class FormatPicker
      SAFETY = 0.95
      # h264 plays everywhere; AV1 only where the device decodes it, so it is used when no h264 fits.
      VIDEO_CODECS = [/\A(avc1|h264)/, /\Aav01/].freeze
      AUDIO_CODEC  = /\A(mp4a|mp3)/
      # audio paired with a video is capped to leave the size budget to the picture on small limits
      SMALL_LIMIT_MB  = 50
      SMALL_LIMIT_ABR = 64

      # clip is the length that is downloaded (a requested section is cut while downloading)
      def initialize(info, limit_mb:, audio_only: false, max_res: nil, clip: info.duration, alang: nil)
        @info, @limit_mb, @audio_only, @max_res, @alang = info, limit_mb, audio_only, max_res, alang
        @budget = limit_mb * 2**20 * SAFETY unless unlimited?
        @ratio  = clip.to_f / info.duration.to_f
      end

      # yt-dlp format ids joined with + (nil when nothing fits)
      def selector
        return unless unlimited? || @info.duration.to_f.positive? # sizes are estimated from the duration

        candidates.select { |c| fits?(c) }.max_by { |c| rank(c) }&.map(&:format_id)&.join('+')
      end

      private

      def unlimited? = @limit_mb.nil?

      # each candidate is the list of formats that would be downloaded together
      def candidates = @audio_only ? audios.map { [_1] } : combined.map { [_1] } + videos.product(audios(cap: max_abr))

      # yt-dlp says 'none' for a stream a format lacks and nothing (nil) for one it does not know
      def combined = formats.select { |f| video?(f) && audio?(f) }
      def videos   = formats.select { |f| video?(f) && f.acodec == 'none' }
      def audios(cap: nil) = preferred_language(formats.select { |f| audio?(f) && f.vcodec == 'none' && (!cap || f.abr.to_f <= cap) })

      def video?(format) = format.vcodec != 'none' && playable?(format.vcodec, *VIDEO_CODECS) && [format.width, format.height].compact.min.to_i <= @max_res
      def audio?(format) = format.acodec != 'none' && playable?(format.acodec, AUDIO_CODEC)
      def playable?(codec, *known) = codec.blank? || known.any? { codec.match?(_1) }

      def max_abr = (SMALL_LIMIT_ABR if !unlimited? && @limit_mb <= SMALL_LIMIT_MB)

      # a better codec outranks a better resolution, and an unknown one comes last
      def rank(candidate) = [-tier(candidate.first), *candidate.map { |f| formats.index(f) }] # yt-dlp lists formats worst to best

      def tier(format) = VIDEO_CODECS.index { format.vcodec.to_s.match?(_1) } || VIDEO_CODECS.size

      def formats = @formats ||= Array(@info.formats)

      # keeps the original audio language first unless another was asked for
      def preferred_language(tracks)
        matching = tracks.select { |f| f.language.to_s.start_with?(@alang.to_s) } if @alang
        matching.presence || tracks
      end

      def fits?(candidate) = unlimited? || within_budget?(candidate)

      def within_budget?(candidate)
        sizes = candidate.map { |f| size(f) }
        sizes.all? && sizes.sum <= @budget
      end

      def size(format)
        bytes = format.filesize || format.filesize_approx || (format.tbr && format.tbr * 125 * @info.duration)
        bytes && bytes * @ratio
      end
    end
  end
end
