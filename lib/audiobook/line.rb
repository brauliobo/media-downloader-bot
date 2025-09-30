module Audiobook
  # Represents a line of text extracted from a document with optional formatting metadata
  class Line
    attr_reader :text, :font_size, :y_position, :page_number

    def initialize(text, font_size: nil, y_position: nil, page_number: nil)
      @text = text.to_s.strip
      @font_size = font_size
      @y_position = y_position
      @page_number = page_number
    end

    def empty?
      @text.empty?
    end

    # Check if font size changed significantly from another line
    def font_changed?(other_line, threshold: 0.10)
      return false unless @font_size && other_line.font_size && other_line.font_size > 0
      diff = (@font_size - other_line.font_size).abs
      diff > 1.0 || diff / other_line.font_size > threshold
    end

    # Check if this line looks like a heading based on text patterns
    def heading_like?
      words = @text.split(/\s+/)
      return false if words.empty? || words.size > 10
      
      # Very short (1-3 words) without sentence-ending punctuation
      return true if words.size <= 3 && @text !~ /[.!?]$/
      
      # Mostly uppercase (>60% of words)
      upper_ratio = words.count { |w| w == w.upcase && w.length > 1 }.fdiv(words.size)
      return true if upper_ratio > 0.6
      
      # Title case without sentence-ending punctuation
      words.all? { |w| w.match?(/\A[A-Z]/) } && @text !~ /[.!?]$/
    end

    def ends_with_punctuation?
      @text =~ /[\.!?¡¿；。？！]"?$/
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
