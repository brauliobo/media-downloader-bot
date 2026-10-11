class TTS
  module Chatterbox
    include HTTPBackend

    configure_backend(
      base_url:      "http://127.0.0.1:#{ENV['CHATTERBOX_PORT']&.to_i || 10250}",
      segment_chars: ENV['CHATTERBOX_SEGMENT_CHARS']&.to_i || 300,
      sample_rate:     24_000,
      sample_rate_env: 'CHATTERBOX_SAMPLE_RATE'
    )

    def self.supports_temperature?
      true
    end

    def synthesize(**kwargs)
      kwargs[:temperature] = ENV['CHATTERBOX_TEMPERATURE']&.to_f || 0.3 if kwargs[:temperature].to_f <= 0
      super
    end

    extend self
  end
end
