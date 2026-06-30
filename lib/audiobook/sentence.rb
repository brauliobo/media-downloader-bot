require 'retriable'
require_relative 'speech'
require_relative '../tts'
require_relative '../text_helpers'

module Audiobook
  # Represents a sentence of text to speak.
  class Sentence < Speech

    PAUSE = 0.10
    PUNCTUATION_ONLY = /\A[\p{P}\p{S}\s]+\z/u

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

    def spoken_text
      speakable? ? text : ''
    end

    def speakable?
      self.class.speakable_text?(text)
    end

    def to_wav(dir, idx, lang: 'en', stl: nil, tts_options: {})
      return nil unless speakable?

      super
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

    def synthesize_audio(wav_path, lang, tts_options: {})
      spoken = spoken_text
      if spoken.empty?
        super # generate silence
      else
        # Retry TTS and fail hard if output is missing
        Retriable.retriable(tries: 4, base_interval: 0.5, multiplier: 2.0) do
          speed, options = AudioFiles.split_speed_options(tts_options)
          TTS.synthesize(text: spoken, lang: lang, out_path: wav_path, **options)
          raise 'TTS produced no audio' unless File.exist?(wav_path) && File.size?(wav_path)
          AudioFiles.speed!(wav_path, speed)
        end
      end
    end

    def extra_hash
      h = { 'text' => text }
      h['references'] = references.map(&:to_h) if references.any?
      h
    end

    def self.ends_with_punctuation?(text)
      TextHelpers.ends_with_punctuation?(text)
    end

    def self.speakable_text?(text)
      normalized = text.to_s.strip
      normalized.present? && !normalized.match?(PUNCTUATION_ONLY)
    end

    def self.build(text)
      new(text_value(text)).then { |sentence| sentence if sentence.speakable? }
    end

    def self.build_all(texts)
      Array(texts).filter_map { |text| build(text) }
    end

    def self.text_value(value)
      value = SymMash.new(value) if value.is_a?(Hash)
      value.respond_to?(:text) ? value.text : value
    end
  end
end
