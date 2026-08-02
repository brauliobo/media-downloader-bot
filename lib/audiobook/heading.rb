require_relative 'sentence'
require_relative '../zipper'

module Audiobook
  # Represents a heading - single sentence with extra pause
  class Heading < Sentence

    PAUSE = Pauses::HEADING

    def initialize(text, language: nil)
      if text.is_a?(Sentence)
        super(text.text, language: language || text.language)
        @font_size = text.font_size if text.respond_to?(:font_size)
        @source_sentence = text.source_sentence if text.respond_to?(:source_sentence)
      else
        super(text, language: language)
      end
    end

    def to_h
      data = { 'text' => text }
      data['language'] = language if language
      { 'heading' => data }
    end
  end
end
