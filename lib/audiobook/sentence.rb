require 'retriable'
require_relative 'speech'
require_relative '../tts'
require_relative '../text_helpers'
require_relative 'font_roles'

module Audiobook
  # Represents a sentence of text to speak.
  class Sentence < Speech

    PAUSE = Pauses::SENTENCE
    PUNCTUATION_ONLY = /\A[\p{P}\p{S}\s]+\z/u

    attr_accessor :text, :source_sentence, :font_size, :alignment, :language, :bold, :italic, :color, :font_name
    attr_writer :references

    def initialize(text, language: nil)
      super()
      @text = text.to_s
        .gsub(/[\u0000-\u001F\u007F-\u009F]/, '') # control chars
        .tr("\x01\x02\x03\x04\x05\x06\x07\x08", '')
        .gsub(/\u00AD/, '')
        .gsub(/\s+/, ' ').strip
      @references = []
      @font_size = nil
      @source_sentence = nil
      @language = language.to_s.strip.presence
      @alignment = nil
      @bold = nil
      @italic = nil
      @color = nil
      @font_name = nil
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
      h['language'] = language if language
      h.merge!(style_hash)
      h['references'] = references.map(&:to_h) if references.any?
      h
    end

    def style_hash
      h = {}
      h['font_size'] = font_size if font_size
      h['alignment'] = alignment.to_s if alignment
      h['bold'] = bold unless bold.nil?
      h['italic'] = italic unless italic.nil?
      h['color'] = color if color
      h['font_name'] = font_name if font_name
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
      new(text_value(text), language: language_value(text)).then do |sentence|
        next unless sentence.speakable?

        copy_style(sentence, wrap(text))
        sentence
      end
    end

    def self.build_all(texts)
      Array(texts).filter_map { |text| build(text) }
    end

    def self.from_text(text)
      build_all(TextHelpers.normalize_text(text).gsub(/([.!?…]\"?)\s+(?=\p{Lu})/u, "\\1\n").split(/\n+/))
    end

    def self.wrap(value)
      value.is_a?(Hash) ? SymMash.new(value) : value
    end

    def self.text_value(value)
      wrap(value).then { |item| item.respond_to?(:text) ? item.text : item }
    end

    def self.language_value(value)
      wrap(value).then { |item| item.language if item.respond_to?(:language) }
    end

    def self.copy_style(sentence, item)
      FontRoles.copy_style(sentence, item)
    end
    private_class_method :copy_style

    class << self
      alias_method :speakable_text?, :speakable_text? unless method_defined?(:speakable_text?)
      alias_method :build_all, :build_all unless method_defined?(:build_all)
    end
  end
end
