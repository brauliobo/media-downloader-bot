require_relative '../sentence'
require_relative '../paragraph'
require_relative '../heading'
require_relative '../section'
require_relative '../../text_helpers'

module Audiobook
  class Paragraph
    class Factory
      MAX_SENTENCE_CHARS = 800

      def self.create_items_from_lines(lines, start_page, max_sentence_chars: MAX_SENTENCE_CHARS)
        new(lines, start_page, max_sentence_chars: max_sentence_chars).create
      end

      def initialize(lines, start_page, max_sentence_chars: MAX_SENTENCE_CHARS)
        @lines = lines
        @start_page = start_page
        @max_sentence_chars = max_sentence_chars
      end

      def create
        return [] if @lines.empty?

        grouped_by_font.map do |group|
          next if group.empty?

          normalized = normalize_group_text(group)
          next if normalized.empty?

          if group.first.section?
            next item_data(group.first, create_section(group.first, normalized))
          end

          sentences = create_sentences(normalized, group.first.language)
          next if sentences.empty?

          create_item(group.first, sentences)
        end.compact
      end

      private

      def grouped_by_font
        groups = []
        current_group = []
        prev_font = nil

        @lines.each do |line|
          if prev_font && line.font_size && (line.font_size != prev_font || line.text.match?(/^\d+$/))
            groups << current_group unless current_group.empty?
            current_group = [line]
          else
            current_group << line
          end
          prev_font = line.font_size
        end
        groups << current_group unless current_group.empty?
        groups
      end

      def normalize_group_text(group)
        normalized = TextHelpers.join_pdf_lines(group.map(&:text))
        normalized.gsub(/\bN\s*\.\s*T\./i, 'N.T.')
      end

      def create_sentences(normalized, language)
        Sentence.build_all(TextHelpers.split_sentences(normalized, max_chars: @max_sentence_chars)).each do |sentence|
          sentence.language = language
        end
      end

      def create_item(first_line, sentences)
        numeric_only = sentences.size == 1 && sentences.first.text.strip.match?(/\A[^\p{L}]*\z/u)

        item = if !numeric_only && sentences.size == 1 && heading_like?(first_line, sentences.first.text)
          create_heading(first_line, sentences.first)
        else
          create_paragraph(first_line, sentences)
        end

        item_data(first_line, item)
      end

      def create_heading(first_line, sentence)
        with_font_size(Heading.new(sentence), first_line)
      end

      def create_section(first_line, text)
        with_font_size(Section.new(text, level: first_line.section_level, language: first_line.language), first_line)
      end

      def create_paragraph(first_line, sentences)
        para = Paragraph.new(sentences)
        if first_line.font_size
          para.sentences.each { |s| s.font_size = first_line.font_size if s.respond_to?(:font_size=) }
        end
        para
      end

      def with_font_size(item, first_line)
        item.font_size = first_line.font_size if item.respond_to?(:font_size=)
        item
      end

      def item_data(first_line, item)
        {item: item, page: @start_page, font_size: first_line.font_size}
      end

      def self.heading_like?(text)
        return false unless text
        return false if text.strip.match?(/\A[^\p{L}]*\z/u)

        words = text.split(/\s+/)
        return false if words.empty? || words.size > 10

        return true if words.size <= 3 && text !~ /[.!?]$/

        upper_ratio = words.count { |w| w == w.upcase && w.length > 1 }.fdiv(words.size)
        return true if upper_ratio > 0.6

        words.all? { |w| w.match?(/\A[A-Z]/) } && text !~ /[.!?]$/
      end

      def heading_like?(first_line, text)
        self.class.heading_like?(text) || first_line.heading_like?
      end
    end
  end
end
