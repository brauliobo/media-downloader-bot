require_relative 'http_backend'

class TTS
  module OmniVoice
    include HTTPBackend

    configure_backend(
      base_url:              ENV['OMNIVOICE_URL'] || "http://127.0.0.1:#{ENV['OMNIVOICE_PORT']&.to_i || 10440}",
      segment_chars:         ENV['OMNIVOICE_SEGMENT_CHARS']&.to_i || 420,
      batch_synth_path:      '/synthesize_batch',
      segment:               false,
      stable_voice_reference: true
    )

    def self.supports_batch_synthesis?
      true
    end

    def synthesize(text:, lang:, out_path:, speaker_wav: nil, ref_text: nil, **kwargs)
      require_clone_text!(speaker_wav, ref_text)
      kwargs = kwargs.merge(ref_text: ref_text, normalize_text: true)
      super(text: text, lang: lang, out_path: out_path, speaker_wav: speaker_wav, **kwargs)
    end

    def synthesize_batch(items:, lang: nil, speaker_wav: nil, ref_text: nil, **kwargs)
      require_clone_text!(speaker_wav, ref_text)
      kwargs = kwargs.merge(ref_text: ref_text, normalize_text: true)
      super(items: items, lang: lang, speaker_wav: speaker_wav, **kwargs)
    end

    def self.output_sample_rate
      TTS.env_sample_rate('OMNIVOICE_SAMPLE_RATE') || 24_000
    end

    private

    def require_clone_text!(speaker_wav, ref_text)
      return unless speaker_wav || ENV['SPEAKER_WAV']
      return unless ref_text.to_s.strip.empty?

      # Without reference text OmniVoice lazily loads its internal Whisper ASR model.
      raise ArgumentError, 'OmniVoice voice cloning requires ref_text'
    end

    extend self
  end
end
