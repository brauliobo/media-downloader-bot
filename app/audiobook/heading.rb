module Audiobook
  # Represents a heading - single sentence with extra pause
  class Heading < Sentence

    PAUSE = Pauses::HEADING
    # An attribution, a rights line and a leftover drop cap never read as a heading, however short they are.
    NEVER      = /\A(?:[—–]|©|\(c\)\s|\p{L}\z)/u
    MAX_WORDS  = 10
    CAPS_RATIO = 0.6

    attr_accessor :role

    # A short line set in title case or in capitals reads as a heading.
    def self.like?(text)
      text = text.to_s.strip
      return false if text.match?(/\A[^\p{L}]*\z/u) || text.match?(NEVER)

      words = text.split(/\s+/)
      return false if words.empty? || words.size > MAX_WORDS
      return true if words.size <= 3 && Text.capital?(text) && !text.match?(/[.!?…,;:]\z/)
      return true if words.count { |word| word == word.upcase && word.length > 1 }.fdiv(words.size) > CAPS_RATIO

      words.all? { |word| word.match?(/\A[A-Z]/) } && !text.match?(/[.!?]\z/)
    end

    def initialize(text, language: nil)
      if text.is_a?(Sentence)
        super(text.text, language: language || text.language)
        FontRoles.copy_style(self, text)
        @source_sentence = text.source_sentence if text.respond_to?(:source_sentence)
      else
        super(text, language: language)
      end
    end

    def to_h
      data = { 'text' => text }
      data['language'] = language if language
      data['role'] = role.to_s if role
      data.merge!(style_hash)
      { 'heading' => data }
    end
  end
end
