class FFmpeg
  # The whole-file jobs run through a one-shot ffmpeg, grouped by what they work on.
  module Operations
    include Extraction
    include Dubbing
    include Audio

    private

    # The channels, sample rate and codec (16-bit PCM unless told otherwise) an audio output is written with.
    def audio_format builder, channels:, sample_rate:, codec: 'pcm_s16le'
      builder.channels channels
      builder.sample_rate sample_rate
      builder.codec codec, stream: :audio if codec
    end
  end
end
