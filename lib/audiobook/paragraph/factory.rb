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
      ISOLATED_MAX_WORDS = 12
      TERMINAL_PUNCTUATION = /[.!?…]["”’)\]»]*\z/u
      CLAUSE_PUNCTUATION   = /[.!?…,;:]["”’)\]»]*\z/u
      # An attribution, a rights line and a leftover drop cap are never headings, however short.
      NEVER_HEADING        = /\A(?:[—–]|©|\(c\)\s|\p{L}\z)/u

      def self.create_items_from_lines(lines, start_page, max_sentence_chars: MAX_SENTENCE_CHARS, isolated: false)
        new(lines, start_page, max_sentence_chars: max_sentence_chars, isolated: isolated).create
      end

      def initialize(lines, start_page, max_sentence_chars: MAX_SENTENCE_CHARS, isolated: false)
        @lines = lines
        @start_page = start_page
        @max_sentence_chars = max_sentence_chars
        @isolated = isolated
      end

      def create
        return [] if @lines.empty?

        grouped_by_font.map do |group|
          next if group.empty?

          normalized = normalize_group_text(group)
          next if normalized.empty?

          if group.first.section?
            next item_data(group, create_section(group.first, TextHelpers.extract_markers(normalized).first))
          end

          sentences = create_sentences(normalized, group.first.language)
          next if sentences.empty?

          create_item(group, sentences)
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
        return false if FontRoles.heading_continuation?(group.last, line) || line.continues?(group.map(&:text).join(' '))
        return true if FontRoles.heading_item?(group.first) != FontRoles.heading_item?(line)
        return true if !FontRoles.heading_item?(group.first) && line.style_changed?(group.first)

        false
      end

      def normalize_group_text(group)
        normalized = TextHelpers.join_pdf_lines(group.map { |line| TextHelpers.strip_toc_leaders(line.text) })
        TextHelpers.strip_bullet(normalized).gsub(/\bN\s*\.\s*T\./i, 'N.T.')
      end

      def create_sentences(normalized, language)
        TextHelpers.split_sentences(normalized, max_chars: @max_sentence_chars).filter_map do |text|
          clean, ids = TextHelpers.extract_markers(text)
          sentence = Sentence.build(clean)
          next unless sentence

          sentence.language = language
          sentence.reference_ids = ids
          sentence
        end
      end

      def create_item(group, sentences)
        first_line = group.first
        numeric_only = sentences.size == 1 && sentences.first.text.strip.match?(/\A[^\p{L}]*\z/u)
        level = FontRoles.current&.level_for(first_line)
        joined = sentences.map(&:text).join(' ')

        item = if !numeric_only && heading_group?(group, level, joined, sentences.size)
          if level.to_i.positive?
            create_section(first_line, joined, level: level)
          else
            create_heading(first_line, joined, language: first_line.language)
          end
        else
          create_paragraph(first_line, sentences)
        end

        item_data(group, item)
      end

      def heading_group?(group, level, joined, sentence_count)
        first_line = group.first
        words = joined.split.size
        return false if words > FontRoles::MAX_HEADING_WORDS || joined.match?(NEVER_HEADING)
        # A contents entry points at a heading elsewhere and a bulleted line is an item in a
        # list; neither is a heading itself, however isolated it looks.
        return false if contents?(group) || TextHelpers.bulleted?(group.first.text)
        # A lowercase opening is prose, an attribution or a caption unless the type outsizes the body.
        if first_line.starts_with_lowercase?
          return false if !larger_than_body?(first_line) || joined.match?(TERMINAL_PUNCTUATION)
        end
        # A label is a complete phrase; text that breaks off mid-sentence is body copy.
        return false if sentence_count > 1 && !joined.match?(TERMINAL_PUNCTUATION)
        return true if @isolated && words <= ISOLATED_MAX_WORDS && !joined.match?(CLAUSE_PUNCTUATION)

        font_heading = level.to_i.positive? || (FontRoles.current && FontRoles.heading_item?(first_line))
        return sentence_count == 1 && heading_like?(group, joined) unless font_heading
        # Emphasis at body size marks a lead-in, not a heading, once it reads as a full sentence.
        return words <= 4 || !joined.match?(TERMINAL_PUNCTUATION) unless larger_than_body?(first_line)

        heading_like?(group, joined) || words <= 20
      end

      def larger_than_body?(line)
        body = FontRoles.current&.body_size
        return true unless body

        FontRoles.size_of(line).to_f >= body + FontRoles::BODY_BAND
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

      def item_data(group, item)
        {item: item, page: @start_page, font_size: group.first.font_size, toc: contents?(group),
         block: group.first.block}
      end

      def contents?(group) = group.any? { |line| TextHelpers.toc_entry?(line.text) }

      def self.heading_like?(text)
        return false unless text
        return false if text.strip.match?(/\A[^\p{L}]*\z/u) || text.strip.match?(NEVER_HEADING)

        words = text.split(/\s+/)
        return false if words.empty? || words.size > 10

        return true if words.size <= 3 && text !~ /[.!?…,;:]\z/

        upper_ratio = words.count { |w| w == w.upcase && w.length > 1 }.fdiv(words.size)
        return true if upper_ratio > 0.6

        words.all? { |w| w.match?(/\A[A-Z]/) } && text !~ /[.!?]$/
      end

      # A list entry is not a heading, and a short opening line says nothing about the block it starts.
      def heading_like?(group, text)
        return false if TextHelpers.enumerated?(text)

        self.class.heading_like?(text) || (group.one? && group.first.heading_like?)
      end
    end
  end
end
