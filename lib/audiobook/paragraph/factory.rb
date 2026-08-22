require_relative '../sentence'
require_relative '../paragraph'
require_relative '../heading'
require_relative '../section'
require_relative '../../text_helpers'
require_relative '../font_roles'

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
          if current_group.any? && split_group?(current_group, line, prev_font)
            groups << current_group
            current_group = [line]
          else
            current_group << line
          end
          prev_font = line.font_size
        end
        groups << current_group unless current_group.empty?
        groups
      end

      def split_group?(group, line, prev_font)
        return true if line.text.match?(/^\d+$/) || FontRoles.labeled_line?(line)
        return true if prev_font && line.font_size && !FontRoles.same_size?(line, group.last)
        return false if FontRoles.heading_continuation?(group.last, line)
        return true if FontRoles.heading_item?(group.first) != FontRoles.heading_item?(line)
        return true if !FontRoles.heading_item?(group.first) && line.style_changed?(group.first)

        false
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
        level = FontRoles.current&.level_for(first_line)
        joined = sentences.map(&:text).join(' ')

        item = if !numeric_only && heading_group?(first_line, level, joined, sentences.size)
          if level.to_i.positive?
            create_section(first_line, joined, level: level)
          else
            create_heading(first_line, joined, language: first_line.language)
          end
        else
          create_paragraph(first_line, sentences)
        end

        item_data(first_line, item)
      end

      def heading_group?(first_line, level, joined, sentence_count)
        words = joined.split.size
        return false if words > FontRoles::MAX_HEADING_WORDS

        font_heading = level.to_i.positive? || (FontRoles.current && FontRoles.heading_item?(first_line))
        if font_heading
          heading_like?(first_line, joined) || words <= 20
        else
          sentence_count == 1 && heading_like?(first_line, joined)
        end
      end

      def create_heading(first_line, text, language: first_line.language)
        with_style(Heading.new(text, language: language), first_line)
      end

      def create_section(first_line, text, level: first_line.section_level)
        with_style(Section.new(text, level: level || 1, language: first_line.language), first_line)
      end

      def create_paragraph(first_line, sentences)
        para = Paragraph.new(sentences)
        sentences.each { |sentence| copy_style(sentence, first_line) }
        para
      end

      def with_style(item, first_line)
        copy_style(item, first_line)
        assign_role(item, first_line)
        item
      end

      def assign_role(item, line)
        return unless item.respond_to?(:role=)

        roles = FontRoles.current
        item.role = if roles
          role = roles.role_for(line)
          if roles.heading?(line) || role == :title
            role
          elsif item.is_a?(Section)
            FontRoles::HEADING_ROLES[item.level - 1] || :subheading
          else
            :heading
          end
        elsif item.is_a?(Section)
          FontRoles::HEADING_ROLES[item.level - 1] || :subheading
        else
          :heading
        end
      end

      def copy_style(item, line)
        FontRoles.copy_style(item, line)
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
