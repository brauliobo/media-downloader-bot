require 'digest'

module Ewprs
  class TranslationBatch
    module DocumentUnitizer
      include TranslationMarkup

      ENGLISH_GRAMMAR_DOCUMENT = /<p\b[^>]*\bclass\s*=\s*["']?title\b[^>]*>\s*<b>Sarkar's English Grammar<\/b>/i
      INSTRUCTIONAL_TABLE = %r{
        (<p\b(?=[^>]*\bclass\s*=\s*["']?table\b)[^>]*>\s*<table\b[^>]*>)
        (.*?)
        (</table\s*>)
      }mix
      TABLE_CELL = %r{(<td\b[^>]*>)(.*?)(</td\s*>)}mi
      TABLE_HEADER_CLASS = /\bclass\s*=\s*["']?[^"'>\s]*Hdr\b/i
      GRAMMAR_WORD_LIST = %r{
        (<b\b[^>]*>)
        ([A-Za-z][A-Za-z'’-]*(?:,\s*[A-Za-z][A-Za-z'’-]*){2,}:)
        (</b\s*>)
      }ix
      LIST_ITEM_PREFIX = /\A(?<prefix>(?:[A-Za-z]|\d{1,3})\)\s+)(?<content>.+)\z/m

      private

      def unitize(html)
        @document_protected = {}
        template = protect_english_grammar_examples(html)
        template = template.gsub(PROTECTED_ELEMENT) { |value| protect_content(value) }
        template = template.gsub(INLINE_ORIGINAL) do |value|
          foreign = validator.protected_source_fragment?(value) || validator.protected_inline_fragment?(value)
          foreign ? protect_content(value) : value
        end
        template = template.gsub(BLOCK_CONTENT) do
          opening, content, closing = Regexp.last_match.captures
          force_translation = opening.match?(/\btype=title\b/i)
          "#{opening}#{register_content(content, force_translation: force_translation)}#{closing}"
        end
        template = unitize_grouped(template, GROUPED_PARAGRAPH)
        template = unitize_grouped(template, GROUPED_DIV, force_translation: true)
        template = template.gsub(TEXT_NODE) do |value|
          translatable?(value) ? register_content(value) : value
        end
        @document_protected.each { |marker, value| template.gsub!(marker, value) }
        template
      ensure
        @document_protected = nil
      end

      def protect_content(value)
        @document_protected ||= {}
        marker = "⟦P#{Digest::SHA256.hexdigest(value)[0, 16]}⟧"
        @document_protected[marker] = value
        @protected += 1
        marker
      end

      def protect_english_grammar_examples(html)
        return html unless html.match?(ENGLISH_GRAMMAR_DOCUMENT)

        protected = html.gsub(INSTRUCTIONAL_TABLE) do
          opening, rows, closing = Regexp.last_match.captures
          protected_rows = rows.gsub(TABLE_CELL) do
            cell_opening, content, cell_closing = Regexp.last_match.captures
            protected = cell_opening.match?(TABLE_HEADER_CLASS) ? content : protect_content(content)
            "#{cell_opening}#{protected}#{cell_closing}"
          end
          "#{opening}#{protected_rows}#{closing}"
        end
        protected.gsub(GRAMMAR_WORD_LIST) do
          opening, words, closing = Regexp.last_match.captures
          "#{opening}#{protect_content(words)}#{closing}"
        end
      end

      def unitize_grouped(template, pattern, force_translation: false)
        template.gsub(pattern) do
          content = Regexp.last_match(2)
          translated = if translatable?(content, force_translation: force_translation)
            register_content(content, force_translation: force_translation)
          else
            content
          end
          "#{Regexp.last_match(1)}#{translated}#{Regexp.last_match(3)}"
        end
      end

      def translatable?(value, force_translation: false)
        core = value.to_s.strip
        return false if core.empty? || core.match?(UNIT_MARKER)
        return false if !force_translation && validator.protected_source_fragment?(core)

        core.gsub(PROTECTED_MARKER, '').match?(/[A-Za-z]/)
      end

      def register_unit(source)
        key = Digest::SHA256.hexdigest([PROMPT_VERSION, target, source].join("\0"))
        @units[key] ||= prepare_unit(key, source)
        "⟦U#{key}⟧"
      end

      def register_content(source, force_translation: false)
        return protect_content(source) if !force_translation && non_english_verse?(source)

        source.split(/(#{STRUCTURAL_MARKUP})/).map do |part|
          if part.empty?
            part
          elsif part.match?(/\A#{STRUCTURAL_MARKUP}\z/)
            part
          else
            if translatable?(part, force_translation: force_translation)
              register_sentences(part, force_translation: force_translation)
            else
              part
            end
          end
        end.join
      end

      def register_sentences(source, force_translation: false)
        leading = source[/\A\s*/m]
        trailing = source[/\s*\z/m]
        core = source[leading.length, source.length - leading.length - trailing.length]
        if core.match?(/\A#{EDITORIAL_CONTENT}\z/)
          opening, content, closing = editorial_parts(core)
          translated = register_sentences(content, force_translation: force_translation)
          return "#{leading}#{opening}#{translated}#{closing}#{trailing}"
        end

        tags = {}
        masked = mask(source, MARKUP, tags)
        masked = mask_editorial_boundaries(masked, tags)
        sentences = SentenceSplitter.split(masked, boundary_tokens: PLACEHOLDER, max_chars: MAX_UNIT_CHARS)
        cursor = 0

        sentences.each_with_object(+'') do |sentence, template|
          index = masked.index(sentence, cursor)
          raise 'sentence splitter changed source content' unless index

          gap = restore_split_markup(masked[cursor...index], tags)
          template << register_split_gap(gap, force_translation: force_translation)
          value = restore_split_markup(sentence, tags)
            translated = if translatable?(value, force_translation: force_translation)
              register_sentence_unit(value)
            else
              value
            end
            template << translated
          cursor = index + sentence.length
        end << register_split_gap(
          restore_split_markup(masked[cursor..], tags), force_translation: force_translation
        )
      end

      def register_split_gap(value, force_translation: false)
        translatable?(value, force_translation: force_translation) ? register_unit(value) : value
      end

      def mask_editorial_boundaries(source, tags)
        depths = Hash.new(0)
        source.gsub(/\[+|\]+|\(+|\)+|[.!?]+/) do |match|
          if match.start_with?('[', '(')
            depths[match[0]] += match.length
            match
          elsif match.start_with?(']', ')')
            opening = match.start_with?(']') ? '[' : '('
            depths[opening] = [depths[opening] - match.length, 0].max
            match
          elsif depths.values.any?(&:positive?)
            marker = format('__P%04d__', tags.size + 1)
            tags[marker] = match
            marker
          else
            match
          end
        end
      end

      def register_sentence_unit(source)
        match = source.match(LIST_ITEM_PREFIX)
        return register_unit(source) unless match

        "#{match[:prefix]}#{register_unit(match[:content])}"
      end

      def restore_split_markup(value, tags)
        value.to_s.gsub(PLACEHOLDER) { |token| tags.fetch(token) }
      end

      def non_english_verse?(source)
        validator.protected_source_fragment?(source)
      end
    end
  end
end
