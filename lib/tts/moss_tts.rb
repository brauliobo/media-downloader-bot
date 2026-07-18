require_relative 'http_backend'

class TTS
  module MossTTS
    include HTTPBackend

    configure_backend(
      base_url:               "http://127.0.0.1:#{ENV['MOSS_TTS_PORT']&.to_i || 10260}",
      segment_chars:          ENV['MOSS_TTS_SEGMENT_CHARS']&.to_i || 500,
      stable_voice_reference: true
    )

    def self.supports_temperature?
      true
    end

    def self.output_sample_rate
      TTS.env_sample_rate('MOSS_TTS_SAMPLE_RATE') || 48_000
    end

    def synthesize(text:, lang:, out_path:, **kwargs)
      if !kwargs.key?(:temperature) || kwargs[:temperature].to_f <= 0
        kwargs[:temperature] = ENV['MOSS_TTS_TEMPERATURE']&.to_f || 1.7
      end
      super(text: text, lang: lang, out_path: out_path, **kwargs)
    end

    extend self
  end
end
