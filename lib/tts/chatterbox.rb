require_relative 'http_backend'

class TTS
  module Chatterbox
    include HTTPBackend

    configure_backend(
      base_url:      "http://127.0.0.1:#{ENV['CHATTERBOX_PORT']&.to_i || 10250}",
      segment_chars: ENV['CHATTERBOX_SEGMENT_CHARS']&.to_i || 300,
      concurrency:   ENV['CHATTERBOX_CONCURRENCY']&.to_i || 1
    )

    def self.supports_temperature?
      true
    end

    def self.output_sample_rate
      TTS.env_sample_rate('CHATTERBOX_SAMPLE_RATE') || 24_000
    end

    def synthesize(text:, lang:, out_path:, **kwargs)
      if !kwargs.key?(:temperature) || kwargs[:temperature].to_f <= 0
        kwargs[:temperature] = ENV['CHATTERBOX_TEMPERATURE']&.to_f || 0.7
      end
      super(text: text, lang: lang, out_path: out_path, **kwargs)
    end

    extend self
  end
end
