class TTS
  module F5TTS
    include HTTPBackend

    configure_backend(
      base_url:      "http://127.0.0.1:#{ENV['F5TTS_PORT']&.to_i || 10240}",
      segment_chars: ENV['F5TTS_SEGMENT_CHARS']&.to_i || 500,
      sample_rate:     24_000,
      sample_rate_env: 'F5TTS_SAMPLE_RATE'
    )

    extend self
  end
end
