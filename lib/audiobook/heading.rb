require_relative 'sentence'
require_relative '../zipper'

module Audiobook
  # Represents a heading - single sentence with extra pause
  class Heading < Sentence

    PAUSE = Pauses::HEADING
    attr_accessor :role

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
