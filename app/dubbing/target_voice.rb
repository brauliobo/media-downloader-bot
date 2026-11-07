module Dubbing
  # A speaker's recorded reference spoken in the target language, to clone instead of the recorded one: cloning an English
  # reference speaks the target language with an English accent, cloning speech already in it keeps the accent.
  # A synthesized copy is a worse clone of the voice and varies from one try to the next, so several are made at once
  # and the one closest to the recorded voice is kept.
  class TargetVoice
    CANDIDATES = 3

    def initialize(reference, text:, lang:, options:, scorer: VoiceClone::EmbeddingScorer.new)
      @reference = reference
      @text      = text
      @lang      = lang
      @options   = options
      @scorer    = scorer
    end

    def call
      TTS::Reference.new(path: speak_candidates.max_by { |path| similarity(path) }, text: @text)
    end

    private

    def speak_candidates
      dir   = File.dirname(@reference.path)
      items = Array.new(CANDIDATES) { |idx| {text: @text, lang: @lang, out_path: File.join(dir, format('target-voice-%d.wav', idx + 1))} }
      TTS.synthesize_batch(items: items, **@options.merge(@reference.tts_options))
      items.map { |item| item.fetch(:out_path) }
    end

    def similarity(path)
      @scorer.call(reference: @reference.path, sample: path).fetch(:cosine_similarity).tap { |score| Rails.logger.info("target voice #{path}: #{score}") }
    end
  end
end
