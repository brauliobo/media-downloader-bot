module Downloaders
  class YtDlp
    class FormatPicker
      # mp4 (h264/AAC) videos: a combined format, or a video-only one paired with an audio-only one.
      class Video < FormatPicker
        VIDEO_CODEC = /\A(avc1|h264)/
        AUDIO_CODEC = /\Amp4a/
        # audio paired with a video is capped to leave the size budget to the picture on small limits
        SMALL_LIMIT_MB  = 50
        SMALL_LIMIT_ABR = 64

        private

        def candidates = combined.map { |f| [f] } + videos.product(audios)

        def combined = formats.select { |f| video?(f) && audio?(f) }
        def videos   = formats.select { |f| video?(f) && f.acodec == 'none' }
        def audios   = preferred_language(formats.select { |f| audio?(f) && f.vcodec == 'none' })

        def max_abr = (SMALL_LIMIT_ABR if @limit_mb <= SMALL_LIMIT_MB)

        def video?(format) = format.ext == 'mp4' && format.vcodec.to_s.match?(VIDEO_CODEC) && [format.width, format.height].compact.min.to_i <= @max_res
        def audio?(format) = format.ext.in?(%w[mp4 m4a]) && format.acodec.to_s.match?(AUDIO_CODEC) && (!max_abr || format.abr.to_f <= max_abr)
      end
    end
  end
end
