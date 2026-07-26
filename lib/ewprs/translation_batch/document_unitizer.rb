require 'digest'

module Ewprs
  class TranslationBatch
    module DocumentUnitizer
      include TranslationMarkup

      private

      def unitize(html)
        @document_protected = {}
        template = html.gsub(PROTECTED_ELEMENT) { |value| protect_content(value) }
        template = template.gsub(INLINE_ORIGINAL) { |value| protect_content(value) }
        template = template.gsub(BLOCK_CONTENT) do
          opening, content, closing = Regexp.last_match.captures
          "#{opening}#{register_content(content)}#{closing}"
        end
        template = unitize_grouped(template, GROUPED_PARAGRAPH)
        template = unitize_grouped(template, GROUPED_DIV)
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

      def unitize_grouped(template, pattern)
        template.gsub(pattern) do
          content = Regexp.last_match(2)
          translated = translatable?(content) ? register_content(content) : content
          "#{Regexp.last_match(1)}#{translated}#{Regexp.last_match(3)}"
        end
      end

      def translatable?(value)
        core = value.to_s.strip
        return false if core.empty? || core.match?(UNIT_MARKER)
        return false if validator.protected_source_fragment?(core)

        core.gsub(PROTECTED_MARKER, '').match?(/[A-Za-z]/)
      end

      def register_unit(source)
        key = Digest::SHA256.hexdigest([PROMPT_VERSION, target, source].join("\0"))
        @units[key] ||= prepare_unit(key, source)
        "⟦U#{key}⟧"
      end

      def register_content(source)
        return protect_content(source) if non_english_verse?(source)

        source.split(/(#{STRUCTURAL_MARKUP})/).map do |part|
          if part.empty?
            part
          elsif part.match?(/\A#{STRUCTURAL_MARKUP}\z/)
            part
          else
            translatable?(part) ? register_sentences(part) : part
          end
        end.join
      end

      def register_sentences(source)
        leading = source[/\A\s*/m]
        trailing = source[/\s*\z/m]
        core = source[leading.length, source.length - leading.length - trailing.length]
        if core.match?(/\A#{EDITORIAL_CONTENT}\z/)
          opening, content, closing = editorial_parts(core)
          return "#{leading}#{opening}#{register_sentences(content)}#{closing}#{trailing}"
        end

        tags = {}
        masked = mask(source, MARKUP, tags)
        masked = mask_editorial_boundaries(masked, tags)
        sentences = SentenceSplitter.split(masked, boundary_tokens: PLACEHOLDER, max_chars: MAX_UNIT_CHARS)
        cursor = 0

        sentences.each_with_object(+'') do |sentence, template|
          index = masked.index(sentence, cursor)
          raise 'sentence splitter changed source content' unless index

          template << restore_split_markup(masked[cursor...index], tags)
          value = restore_split_markup(sentence, tags)
          template << (translatable?(value) ? register_unit(value) : value)
          cursor = index + sentence.length
        end << restore_split_markup(masked[cursor..], tags)
      end

      def mask_editorial_boundaries(source, tags)
        depth = 0
        source.gsub(/\[+|\]+|[.!?]+/) do |match|
          if match.start_with?('[')
            depth += match.length
            match
          elsif match.start_with?(']')
            depth = [depth - match.length, 0].max
            match
          elsif depth.positive?
            marker = format('__P%04d__', tags.size + 1)
            tags[marker] = match
            marker
          else
            match
          end
        end
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
