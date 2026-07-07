require_relative 'http_backend'

class TTS
  module Piper
    include HTTPBackend

    configure_backend(
      base_url:      "http://127.0.0.1:#{ENV['PIPER_PORT']&.to_i || 10222}",
      segment_chars: ENV['PIPER_SEGMENT_CHARS']&.to_i || 500,
      concurrency:   ENV['PIPER_CONCURRENCY']&.to_i || 1
    )

    def self.output_sample_rate
      TTS.env_sample_rate('PIPER_SAMPLE_RATE') || 22_050
    end

    extend self
  end
end
