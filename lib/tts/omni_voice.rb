require_relative 'http_backend'

class TTS
  module OmniVoice
    include HTTPBackend

    configure_backend(
      base_url:      "http://127.0.0.1:#{ENV['OMNIVOICE_PORT']&.to_i || 10440}",
      segment_chars: ENV['OMNIVOICE_SEGMENT_CHARS']&.to_i || 420,
      concurrency:   ENV['OMNIVOICE_CONCURRENCY']&.to_i || 1
    )

    def self.supports_speech_speed?
      true
    end

    def self.supports_temperature?
      true
    end

    def synthesize(text:, lang:, out_path:, **kwargs)
      kwargs[:temperature] = kwargs.delete(:temp) if kwargs.key?(:temp) && !kwargs.key?(:temperature)
      temperature = kwargs.delete(:temperature) { 0 }
      kwargs[:position_temperature] ||= temperature
      kwargs[:class_temperature]    ||= temperature
      super(text: text, lang: lang, out_path: out_path, **kwargs)
    end

    extend self
  end
end
