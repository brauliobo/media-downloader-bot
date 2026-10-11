module Ewprs
  class TranslationValidator
    # What a translation must keep of the source's shape: its lines, delimiters, character references and quotes.
    module Structure
      include Lexicon

      private

      def validate_line_breaks!(source, translated)
        return if line_breaks(source) == line_breaks(translated)

        raise Error.new(:line_breaks, 'translation changed line breaks')
      end

      def validate_delimiters!(source, translated)
        source_text = visible_text(source)
        translated_text = visible_text(translated)
        source_profile = balanced_delimiter_profile(source_text)
        translated_profile = balanced_delimiter_profile(translated_text)
        changed = if CJK_TARGET.key?(target_language) && source_profile
          source_profile != translated_profile
        else
          source_text.scan(DELIMITER) != translated_text.scan(DELIMITER)
        end
        changed ||= source_text.scan(EDITORIAL_BRACKET) != translated_text.scan(EDITORIAL_BRACKET)
        raise Error.new(:delimiters, 'translation changed paired delimiters') if changed
      end

      def balanced_delimiter_profile(value)
        openings = DELIMITER_PAIRS.keys.to_h { |opening| [opening, true] }
        closing_to_opening = DELIMITER_PAIRS.invert
        roots = []
        stack = []
        value.scan(DELIMITER).each do |delimiter|
          if openings.key?(delimiter)
            stack << [delimiter, []]
            next
          end

          opening = closing_to_opening.fetch(delimiter)
          return unless stack.last&.first == opening

          node_opening, children = stack.pop
          signature = "#{node_opening}#{children.join}#{delimiter}"
          stack.empty? ? roots << signature : stack.last.last << signature
        end
        return unless stack.empty?

        roots.sort
      end

      def validate_escaped_character_references!(source, translated)
        source_count     = source.to_s.scan(ESCAPED_CHARACTER_REFERENCE).size
        translated_count = translated.to_s.scan(ESCAPED_CHARACTER_REFERENCE).size
        return if translated_count <= source_count

        raise Error.new(:entities, 'translation introduced an escaped HTML character reference')
      end

      def validate_smart_quotes!(source, translated)
        if balanced_double_quotes?(source) && !balanced_double_quotes?(translated)
          raise Error.new(:quotes, 'translation reversed smart quotes')
        end
        return if translated.to_s.scan(EMPTY_SMART_QUOTES).size <= source.to_s.scan(EMPTY_SMART_QUOTES).size

        raise Error.new(:quotes, 'translation introduced empty smart quotes')
      end

      def balanced_double_quotes?(value)
        openings = []
        value.to_s.scan(DOUBLE_SMART_QUOTE).all? do |quote|
          if quote == '“' && openings.last == :german
            openings.pop
          elsif quote.match?(/&ldquo;|[“«]/i)
            openings << :standard
          elsif quote == '„'
            openings << :german
          else
            openings.pop || false
          end
        end && openings.empty?
      end

      def validate_internal_transport_markers!(source, translated)
        return if translated.to_s.scan(INTERNAL_TRANSPORT_MARKER).size <=
                  source.to_s.scan(INTERNAL_TRANSPORT_MARKER).size

        raise Error.new(:markers, 'translation leaked an internal transport marker')
      end

      def line_breaks(value)
        value.to_s.scan(/\r\n|\r|\n/)
      end

      def visible_text(value)
        CGI.unescapeHTML(value.to_s.gsub(MARKUP, ' ').gsub(MARKER, ' ')).split.join(' ')
      end
    end
  end
end
