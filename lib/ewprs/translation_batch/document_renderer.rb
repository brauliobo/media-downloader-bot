module Ewprs
  class TranslationBatch
    module DocumentRenderer
      include TranslationMarkup

      private

      def render(document, translations)
        rendered = document.template
        rendered = rendered.gsub(UNIT_MARKER) { translations.fetch(Regexp.last_match(1)) } while rendered.match?(UNIT_MARKER)
        normalize_duplicate_dashes(rendered)
      end

      def validate_structure!(source, translated)
        raise 'HTML structure changed during translation' unless html_structure_compatible?(source, translated)

        source_slokas = matches(source, PROTECTED_ELEMENT).select { |value| value.match?(/Para_Sloka/) }
        translated_slokas = matches(translated, PROTECTED_ELEMENT).select { |value| value.match?(/Para_Sloka/) }
        raise 'Para_Sloka content changed during translation' unless translated_slokas == source_slokas

        source_brackets     = source.scan(EDITORIAL_BRACKET)
        translated_brackets = translated.scan(EDITORIAL_BRACKET)
        raise 'editorial brackets changed during translation' unless translated_brackets == source_brackets
      end

      def matches(value, pattern)
        value.to_enum(:scan, pattern).map { Regexp.last_match[0] }
      end

      def class_inventory(documents)
        counts = CONTENT_CLASSES.to_h { |name| [name, 0] }
        documents.each do |html|
          CONTENT_CLASSES.each do |name|
            pattern = name == 'center' ? /<center\b/i : /\bclass\s*=\s*["']?#{Regexp.escape(name)}\b/i
            counts[name] += 1 if html.match?(pattern)
          end
        end
        counts
      end
    end
  end
end
