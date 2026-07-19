require_relative 'http_backend'

class TTS
  module OmniVoice
    include HTTPBackend

    configure_backend(
      base_url:              "http://127.0.0.1:#{ENV['OMNIVOICE_PORT']&.to_i || 10440}",
      segment_chars:         ENV['OMNIVOICE_SEGMENT_CHARS']&.to_i || 420,
      batch_synth_path:      '/synthesize_batch',
      segment:               false,
      stable_voice_reference: true
    )

    def self.supports_batch_synthesis?
      true
    end

    def self.output_sample_rate
      TTS.env_sample_rate('OMNIVOICE_SAMPLE_RATE') || 24_000
    end

    extend self
  end
end
