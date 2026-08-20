require_relative '../text_helpers'
require_relative 'font_roles'

module Audiobook
  # Represents a line of text extracted from a document with optional formatting metadata
  class Line
    attr_reader :text, :font_size, :y_position, :page_number, :x_position, :x_max, :page_width,
                :top_spacing, :bottom_spacing, :section_level, :language, :alignment,
                :bold, :italic, :color, :font_name

    def initialize(text, font_size: nil, y_position: nil, page_number: nil, x_position: nil, x_max: nil,
                   page_width: nil, top_spacing: nil, bottom_spacing: nil, section_level: nil, language: nil,
                   alignment: nil, bold: nil, italic: nil, color: nil, font_name: nil)
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
      @alignment = alignment || FontRoles.alignment_for(x: x_position, x_max: x_max, page_width: page_width)
      @bold = bold
      @italic = italic
      @color = color
      @font_name = font_name
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
        bold: bold, italic: italic, color: color, font_name: font_name
      }
    end

    def font_changed?(other_line, threshold: 0.10)
      return false unless @font_size && other_line.font_size && other_line.font_size > 0
      diff = (@font_size - other_line.font_size).abs
      diff > 1.0 || diff / other_line.font_size > threshold
    end

    def style_changed?(other_line)
      return true if font_changed?(other_line)
      return true if !bold.nil? && !other_line.bold.nil? && bold != other_line.bold
      return true if %i[center right].include?(alignment) && alignment != other_line.alignment

      false
    end

    def heading_like?
      return false if @text.strip.match?(/\A[^\p{L}]*\z/u)

      words = @text.split(/\s+/)
      return false if words.empty? || words.size > 10
      return true if words.size <= 3 && starts_with_capital? && @text !~ /[.!?]$/

      upper_ratio = words.count { |w| w == w.upcase && w.length > 1 }.fdiv(words.size)
      return true if upper_ratio > 0.6

      words.all? { |w| w.match?(/\A[A-Z]/) } && @text !~ /[.!?]$/
    end

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
      @text.end_with?('-')
    end

    def starts_with_lowercase?
      @text.match?(/\A\p{Ll}/u)
    end

    def word_count
      @text.split(/\s+/).size
    end
  end
end
