require_relative '../text_helpers'
require_relative 'font_roles'

module Audiobook
  # Represents a line of text extracted from a document with optional formatting metadata
  class Line
    attr_reader :text, :font_size, :y_position, :page_number, :x_position, :x_max, :page_width,
                :top_spacing, :bottom_spacing, :section_level, :language, :alignment,
                :bold, :italic, :color, :font_name, :block

    def initialize(text, font_size: nil, y_position: nil, page_number: nil, x_position: nil, x_max: nil,
                   page_width: nil, top_spacing: nil, bottom_spacing: nil, section_level: nil, language: nil,
                   alignment: nil, bold: nil, italic: nil, color: nil, font_name: nil, shared_edge: false,
                   block: nil)
      @text = text.to_s.strip
      @font_size = font_size
      @y_position = y_position
      @page_number = page_number
      @x_position = x_position
      @x_max = x_max
      @page_width = page_width
      @top_spacing = top_spacing
      @bottom_spacing = bottom_spacing
      @section_level = section_level&.to_i
      @language = language.to_s.strip.presence
      @alignment = alignment ||
        FontRoles.alignment_for(x: x_position, x_max: x_max, page_width: page_width, shared_edge: shared_edge)
      @bold = bold
      @italic = italic
      @color = color
      @font_name = font_name
      # Which source block this line came from, where the source draws blocks itself. A page of
      # type does not, and leaves it nil for the geometry to answer instead.
      @block = block
    end

    def empty?
      @text.empty?
    end

    def style_attrs
      {
        font_size: font_size, y_position: y_position, page_number: page_number,
        x_position: x_position, x_max: x_max, page_width: page_width,
        top_spacing: top_spacing, bottom_spacing: bottom_spacing,
        section_level: section_level, language: language, alignment: alignment,
        bold: bold, italic: italic, color: color, font_name: font_name, block: block
      }
    end

    def font_changed?(other_line)
      return false unless @font_size && other_line.font_size && other_line.font_size > 0

      !FontRoles.same_size?(self, other_line)
    end

    def style_changed?(other_line)
      return true if font_changed?(other_line)
      return true if !bold.nil? && !other_line.bold.nil? && bold != other_line.bold
      return true if %i[center right].include?(alignment) && alignment != other_line.alignment

      false
    end

    def heading_like? = TextHelpers.heading_like?(@text)

    def section?
      section_level.to_i.positive?
    end

    def ends_with_punctuation?
      TextHelpers.ends_with_punctuation?(@text)
    end

    def starts_with_capital?
      @text.match?(/\A\p{Lu}/u)
    end

    def ends_with_hyphen?
      @text.match?(TextHelpers::TRAILING_HYPHEN)
    end

    def dehyphenate(text) = @text.sub(TextHelpers::TRAILING_HYPHEN, '') + text

    def starts_with_lowercase?
      @text.match?(/\A\p{Ll}/u)
    end

    # A closing quote ends the sentence before it, wherever the text layer put it on the page.
    CLOSING_QUOTE = /\A[”’»\)\]]/u

    def closes_quote? = @text.match?(CLOSING_QUOTE)

    # A lowercase start after text that has not closed its sentence carries that sentence on.
    # An ellipsis is a pause rather than a close when what follows it is lowercase.
    def continues?(text)
      return false unless starts_with_lowercase? && !TextHelpers.enumerated?(@text)

      !TextHelpers.ends_with_punctuation?(text) || TextHelpers.ends_with_ellipsis?(text)
    end

    # The source numbered the two lines as separate blocks, so it drew the boundary itself. A
    # source that numbers no blocks says nothing, and the reading falls back to the page.
    def new_block?(other) = !!(block && other.block && block != other.block)

    def word_count
      @text.split(/\s+/).size
    end
  end
end
