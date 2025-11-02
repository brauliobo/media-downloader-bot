require_relative 'speech'
require_relative '../tts'
require_relative '../text_helpers'

module Audiobook
  # Represents a sentence of text to speak.
  class Sentence < Speech

    PAUSE = 0.10

    attr_reader :text
    attr_writer :references
    attr_accessor :source_sentence, :font_size

    def initialize(text)
      super()
      @text = text.to_s
        .gsub(/[\u0000-\u001F\u007F-\u009F]/, '') # control chars
        .tr("\x01\x02\x03\x04\x05\x06\x07\x08", '')
        .gsub(/\u00AD/, '')
        .gsub(/\s+/, ' ').strip
      @references = []
      @font_size = nil
      @source_sentence = nil
    end

    def references
      @references ||= []
    end

    def add_reference(ref)
      return unless ref
      existing = references.find { |r| r.id == ref.id }
      if existing
        existing
      else
        references << ref
        ref.source_sentence ||= self
        ref
      end
    end

    protected

    def synthesize_audio(wav_path, lang)
      spoken = text.sub(/\s*[\p{P}]+\z/u, '')
      if spoken.empty?
        super # generate silence
      else
        # Retry TTS and fail hard if output is missing
        Manager.retriable(tries: 4, base_interval: 0.5, multiplier: 2.0) do |_attempt|
          TTS.synthesize(text: spoken, lang: lang, out_path: wav_path)
          raise 'TTS produced no audio' unless File.exist?(wav_path) && File.size?(wav_path)
        end
      end
    end

    def extra_hash
      h = { 'text' => text }
      h['references'] = references.map(&:to_h) if references && !references.empty?
      h
    end

    def self.ends_with_punctuation?(text)
      TextHelpers.ends_with_punctuation?(text)
    end
  end
end
