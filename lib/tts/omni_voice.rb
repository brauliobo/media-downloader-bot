require_relative 'http_backend'

class TTS
  module OmniVoice
    include HTTPBackend

    configure_backend(
      base_url:         "http://127.0.0.1:#{ENV['OMNIVOICE_PORT']&.to_i || 10440}",
      segment_chars:    ENV['OMNIVOICE_SEGMENT_CHARS']&.to_i || 420,
      concurrency:      ENV['OMNIVOICE_CONCURRENCY']&.to_i || 1,
      batch_synth_path: ENV['OMNIVOICE_BATCH_SYNTH_PATH'] || '/synthesize_batch',
      segment:          false
    )

    def self.supports_temperature?
      true
    end

    def self.supports_batch_synthesis?
      batch_synth_path.present?
    end

    def self.output_sample_rate
      TTS.env_sample_rate('OMNIVOICE_SAMPLE_RATE') || 24_000
    end

    def synthesize(text:, lang:, out_path:, **kwargs)
      normalize_options!(kwargs)
      super(text: text, lang: lang, out_path: out_path, **kwargs)
    end

    def synthesize_batch(items:, **kwargs)
      normalize_options!(kwargs)
      super(items: items, **kwargs)
    end

    def normalize_options!(kwargs)
      kwargs[:temperature] = kwargs.delete(:temp) if kwargs.key?(:temp) && !kwargs.key?(:temperature)
      temperature = kwargs.delete(:temperature) { 0 }
      kwargs[:position_temperature] ||= temperature
      kwargs[:class_temperature]    ||= temperature
    end

    extend self
  end
end
