require_relative '../sentence'
require_relative '../paragraph'
require_relative '../heading'
require_relative '../../text_helpers'

module Audiobook
  class Paragraph
    class Factory
      def self.create_items_from_lines(lines, start_page)
        new(lines, start_page).create
      end

      def initialize(lines, start_page)
        @lines = lines
        @start_page = start_page
      end

      def create
        return [] if @lines.empty?

        grouped_by_font.map do |group|
          next if group.empty?

          normalized = normalize_group_text(group)
          next if normalized.empty?

          sentences = create_sentences(normalized)
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

      def create_sentences(normalized)
        TextHelpers.split_sentences(normalized)
          .map { |s| Sentence.new(s) }
          .reject { |s| s.text.empty? }
      end

      def create_item(first_line, sentences)
        numeric_only = sentences.size == 1 && sentences.first.text.strip.match?(/\A[^\p{L}]*\z/u)

        item = if !numeric_only && sentences.size == 1 && heading_like?(first_line, sentences.first.text)
          create_heading(first_line, sentences.first)
        else
          create_paragraph(first_line, sentences)
        end

        { item: item, page: @start_page, font_size: first_line.font_size }
      end

      def create_heading(first_line, sentence)
        sentence.font_size = first_line.font_size if sentence.respond_to?(:font_size=)
        Heading.new(sentence)
      end

      def create_paragraph(first_line, sentences)
        para = Paragraph.new(sentences)
        if first_line.font_size
          para.sentences.each { |s| s.font_size = first_line.font_size if s.respond_to?(:font_size=) }
        end
        para
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
