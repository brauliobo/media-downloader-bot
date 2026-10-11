class FFmpeg
  # The whole-file jobs run through a one-shot ffmpeg, grouped by what they work on.
  module Operations
    include Extraction
    include Dubbing
    include Audio
  end
end
