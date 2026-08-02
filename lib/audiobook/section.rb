require_relative 'heading'

module Audiobook
  # Represents a spoken subheading and the boundary that starts its section.
  class Section < Heading
    PAUSE = Pauses::SECTION

    attr_reader :level

    def initialize(text, level: 1, language: nil)
      super(text, language: language)
      @level = [level.to_i, 1].max
    end

    def title = text

    def to_h
      data = { 'text' => text, 'level' => level }
      data['language'] = language if language
      { 'section' => data }
    end
  end
end
