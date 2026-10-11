module Ewprs
  class Translator
    # Protected values travel to the model as markers it will not translate, and come back in place.
    module Placeholders
      private

      def encode_translation_placeholders(text)
        encoded, replacements = encode_character_references(text)
        encoded = encoded.gsub(INTERNAL_PLACEHOLDER) do |placeholder|
          marker = "ZXQEWPRSP#{placeholder[/\d+/].to_i}ZXQ"
          replacements[marker] = placeholder
          marker
        end
        [encoded, replacements]
      end

      def encode_character_references(text)
        replacements = {}
        encoded = text.to_s.gsub(CHARACTER_REFERENCE).with_index do |reference, index|
          marker = encoded_character_reference(reference, index)
          replacements[marker] = reference
          marker
        end
        [encoded, replacements]
      end

      def restore_encoded_placeholders(text, replacements)
        text.to_s.gsub(/#{WIRE_PLACEHOLDER}|#{XML_QUOTE_PLACEHOLDER}/) do |marker|
          replacements.fetch(complete_wire_placeholder(marker), marker)
        end
      end

      def placeholder_mapping(text)
        placeholders = text.to_s.scan(INTERNAL_PLACEHOLDER).uniq.to_h do |marker|
          [marker, "ZXQEWPRSP#{marker[/\d+/].to_i}ZXQ"]
        end
        text.to_s.scan(CHARACTER_REFERENCE).uniq.each_with_index do |reference, index|
          placeholders[reference] = encoded_character_reference(reference, index)
        end
        placeholders
      end

      def replace_placeholders(text, placeholders)
        text.to_s.gsub(/#{INTERNAL_PLACEHOLDER}|#{CHARACTER_REFERENCE}/) do |marker|
          placeholders.fetch(marker, marker)
        end
      end

      def restore_placeholders(text, placeholders)
        internal = placeholders.invert
        text.to_s.gsub(/#{WIRE_PLACEHOLDER}|#{XML_QUOTE_PLACEHOLDER}/) do |marker|
          internal.fetch(complete_wire_placeholder(marker), marker)
        end
      end

      def complete_wire_placeholder(marker)
        marker.start_with?('ZXQEWPRS') && !marker.end_with?('ZXQ') ? "#{marker}ZXQ" : marker
      end

      def encoded_character_reference(reference, index)
        quote = SMART_QUOTE_REFERENCE[reference.downcase]
        quote ? %(<ewprs-#{quote} id="#{index + 1}"/>) : "ZXQEWPRSE#{index + 1}ZXQ"
      end

      def natural_placeholder_value(value)
        plain = value.to_s.gsub(/<[^>]+>|⟦U[0-9a-f]{64}⟧/, ' ')
        plain = plain.gsub(CHARACTER_REFERENCE) { natural_character_reference(Regexp.last_match[0]) }
        plain.unicode_normalize(:nfd).gsub(/\p{M}/u, '').strip
      end

      def natural_character_reference(reference)
        NATURAL_CHARACTER_REFERENCE.fetch(reference.downcase) { CGI.unescapeHTML(reference) }
      end

      def natural_phrase_pattern(value)
        opening = value.match?(/\A\p{L}/u) ? '(?<!\p{L})' : ''
        closing = value.match?(/\p{L}\z/u) ? '(?!\p{L})' : ''
        Regexp.new("#{opening}#{Regexp.escape(value)}#{closing}", Regexp::IGNORECASE)
      end

      def restore_natural_character_references(output, source)
        source.to_s.scan(CHARACTER_REFERENCE).each_with_object(output) do |reference, restored|
          natural = natural_character_reference(reference)
          next if natural == reference

          pattern = SMART_QUOTE_REFERENCE.key?(reference.downcase) ? NATURAL_SMART_QUOTE : Regexp.new(Regexp.escape(natural))
          return unless restored.sub!(pattern, reference)
        end
      end

      def remove_echoed_source(output, source)
        stripped = output.to_s.sub(/\A#{Regexp.escape(source.to_s.strip)}[ \t]*(?:\r?\n[ \t]*)+/, '')
        stripped.empty? ? output : stripped
      end
    end
  end
end
