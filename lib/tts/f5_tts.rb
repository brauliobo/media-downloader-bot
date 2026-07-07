require_relative 'http_backend'

class TTS
  module F5TTS
    include HTTPBackend

    configure_backend(
      base_url:      "http://127.0.0.1:#{ENV['F5TTS_PORT']&.to_i || 10240}",
      segment_chars: ENV['F5TTS_SEGMENT_CHARS']&.to_i || 500,
      concurrency:   ENV['F5TTS_CONCURRENCY']&.to_i || 1
    )

    def self.output_sample_rate
      TTS.env_sample_rate('F5TTS_SAMPLE_RATE') || 24_000
    end

    extend self
  end
end
