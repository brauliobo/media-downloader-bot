module Downloaders
  class YtDlp
    class FormatPicker
      # m4a (AAC) and mp3 tracks, with no bitrate cap: there is no picture to leave the size budget to.
      class Audio < FormatPicker
        CODEC = /\A(mp4a|mp3)/
        EXTS  = %w[m4a mp3].freeze

        private

        def candidates = preferred_language(formats.select { |f| track?(f) }).map { |f| [f] }

        def track?(format) = format.vcodec == 'none' && format.ext.in?(EXTS) && format.acodec.to_s.match?(CODEC)
      end
    end
  end
end
