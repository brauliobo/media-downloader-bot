class TTS
  module Piper
    include HTTPBackend

    configure_backend(
      base_url:      "http://127.0.0.1:#{ENV['PIPER_PORT']&.to_i || 10222}",
      segment_chars: ENV['PIPER_SEGMENT_CHARS']&.to_i || 500,
      sample_rate:     22_050,
      sample_rate_env: 'PIPER_SAMPLE_RATE'
    )

    extend self
  end
end
