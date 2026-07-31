require_relative 'heading'

module Audiobook
  # Represents a spoken subheading and the boundary that starts its section.
  class Section < Heading
    PAUSE = Pauses::SECTION

    attr_reader :level

    def initialize(text, level: 1)
      super(text)
      @level = [level.to_i, 1].max
    end

    def title = text

    def to_h
      { 'section' => { 'text' => text, 'level' => level } }
    end
  end
end
