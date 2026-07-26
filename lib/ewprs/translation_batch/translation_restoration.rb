require 'cgi'

module Ewprs
  class TranslationBatch
    module TranslationRestoration
      include TranslationMarkup

      private

      def restore_tokens_with_retries(unit, output)
        retries = 0
        begin
          validator.validate!(source: unit.prepared, translated: output)
          restore_tokens(unit, output)
        rescue ProtectedTokenError, TranslationValidator::Error => error
          raise if retries >= TOKEN_RETRIES

          retries += 1
          stdout.puts "retrying invalid translation #{unit.key} (#{retries}/#{TOKEN_RETRIES}): #{error.message}"
          output = translator.repair_markup(
            unit.prepared, invalid: output, issue: error.message,
            tokens: repair_token_values(unit.tokens), from: source_language, to: target
          )
          retry
        end
      end

      def repair_token_values(tokens)
        tokens.transform_values do |value|
          value.gsub(UNIT_MARKER) { @units.fetch(Regexp.last_match(1)).source }
        end
      end

      def restore_tokens(unit, output)
        output = normalize_protected_boundaries(unit, output.to_s)
        expected = unit.prepared.scan(PLACEHOLDER)
        actual   = output.scan(PLACEHOLDER)
        unless actual.tally == expected.tally
          expected_counts = expected.tally
          actual_counts   = actual.tally
          missing = expected_counts.flat_map do |marker, count|
            [marker] * [count - actual_counts.fetch(marker, 0), 0].max
          end
          unexpected = actual_counts.flat_map do |marker, count|
            [marker] * [count - expected_counts.fetch(marker, 0), 0].max
          end
          details = []
          details << "missing: #{missing.join(', ')}" unless missing.empty?
          details << "unexpected: #{unexpected.join(', ')}" unless unexpected.empty?
          raise ProtectedTokenError,
                "translation changed protected tokens for #{unit.key} (#{details.join('; ')})"
        end

        unless output.scan(EDITORIAL_TAG) == unit.prepared.scan(EDITORIAL_TAG)
          raise ProtectedTokenError, "translation changed editorial tags for #{unit.key}"
        end
        unless valid_editorial_structure?(unit, output)
          raise ProtectedTokenError, "translation changed editorial tags for #{unit.key}"
        end

        unless valid_structural_order?(unit, expected, actual) && valid_structural_adjacency?(unit, output)
          raise ProtectedTokenError, "translation reordered structural tokens for #{unit.key}"
        end

        translated = restore_editorial_tags(output).split(/(#{PLACEHOLDER})/).map do |part|
          unit.tokens.fetch(part) { preserve_entities(CGI.escapeHTML(part)) }
        end.join
        validate_restored_translation!(unit, "#{unit.leading}#{translated}#{unit.trailing}")
      end

      def normalize_protected_boundaries(unit, output)
        unit.tokens.each_with_object(output.dup) do |(marker, value), normalized|
          visible = CGI.unescapeHTML(value.gsub(MARKUP, ' ').gsub(UNIT_MARKER, ' ')).strip
          normalized.gsub!(/(?<=\p{Latin})#{Regexp.escape(marker)}/u, " #{marker}") if visible.match?(/\A\p{L}/u)
          normalized.gsub!(/#{Regexp.escape(marker)}(?=\p{Latin})/u, "#{marker} ") if visible.match?(/\p{L}\z/u)
        end
      end

      def restore_editorial_tags(value)
        closing_depths = []
        restored = value.gsub(EDITORIAL_TAG) do |tag|
          if tag.match?(/\A<span/i)
            opening, closing = tag.match(/data-ewprs="([12])([12])"/i).captures
            closing_depths << closing.to_i
            '[' * opening.to_i
          else
            closing = closing_depths.pop
            raise ProtectedTokenError, 'translation left editorial tags unbalanced' unless closing

            ']' * closing
          end
        end
        raise ProtectedTokenError, 'translation left editorial tags unbalanced' unless closing_depths.empty?

        restored
      end

      def valid_structural_order?(unit, expected, actual)
        expected_structure = expected.select { |token| structural_token?(unit.tokens.fetch(token)) }
        actual_structure   = actual.select { |token| structural_token?(unit.tokens.fetch(token)) }
        return true if actual_structure == expected_structure

        pairs = movable_inline_pairs(expected_structure, unit.tokens)
        return false if pairs.empty?

        movable = pairs.flatten.to_h { |token| [token, true] }
        expected_anchors = expected_structure.reject { |token| movable.key?(token) }
        actual_anchors   = actual_structure.reject { |token| movable.key?(token) }
        return false unless actual_anchors == expected_anchors

        pairs.all? do |opening, closing|
          expected_index = expected_structure.index(opening)
          actual_index   = actual_structure.index(opening)
          next false unless actual_index && actual_structure[actual_index + 1] == closing

          expected_structure[..expected_index].count { |token| !movable.key?(token) } ==
            actual_structure[..actual_index].count { |token| !movable.key?(token) }
        end
      end

      def valid_structural_adjacency?(unit, output)
        structural_adjacencies(unit.prepared, unit.tokens).tally ==
          structural_adjacencies(output, unit.tokens).tally
      end

      def valid_editorial_structure?(unit, output)
        return true unless unit.prepared.match?(EDITORIAL_TAG)

        editorial_structure(unit.prepared, unit.tokens) == editorial_structure(output, unit.tokens)
      end

      def editorial_structure(value, tokens)
        value.to_s.scan(/#{PLACEHOLDER}|#{EDITORIAL_TAG}/).select do |part|
          part.match?(EDITORIAL_TAG) || begin
            protected = tokens.fetch(part)
            structural_token?(protected) || protected.match?(PAIRED_DELIMITER)
          end
        end
      end

      def structural_adjacencies(value, tokens)
        value.to_s.scan(/(?=(#{PLACEHOLDER})(#{PLACEHOLDER}))/).select do |left, right|
          structural_token?(tokens.fetch(left)) && structural_token?(tokens.fetch(right))
        end
      end

      def movable_inline_pairs(structure, tokens)
        structure.each_cons(2).filter_map do |opening, closing|
          opening_tag = tokens.fetch(opening)[/\A<(i|em)\b[^>]*>\z/i, 1]
          closing_tag = tokens.fetch(closing)[/\A<\/(i|em)\s*>\z/i, 1]
          [opening, closing] if opening_tag && closing_tag&.casecmp?(opening_tag)
        end
      end

      def structural_token?(value)
        value.match?(STANDALONE_MARKUP) || value.match?(/\A#{EDITORIAL_BRACKET}\z/)
      end

      def validate_restored_translation!(unit, translation)
        validation_source, validation_translation = project_nested_values(unit, translation)
        if unit.source && validation_source.scan(HTML_STRUCTURE) != validation_translation.scan(HTML_STRUCTURE)
          raise TranslationValidator::Error.new(:markup, 'translation changed HTML tag sequence')
        end

        protected_values = protected_value_counts(unit)
        progress_values = protected_values.reject { |value, _count| value.match?(UNIT_MARKER) }
        validator.validate!(
          source: validation_source, translated: validation_translation,
          protected_values: progress_values
        )
        validator.validate_protected!(
          source: unit.source, translated: translation, protected_values: protected_values
        )
        translation
      end

      def project_nested_values(unit, translation)
        nested_tokens = unit.tokens.select { |_marker, value| value.match?(UNIT_MARKER) }
        return [unit.source.dup, translation.dup] if nested_tokens.empty?

        source = restore_editorial_tags(unit.prepared).gsub(PLACEHOLDER) do |marker|
          unit.tokens.fetch(marker)
        end
        translated = translation.dup
        nested_tokens.each do |marker, value|
          unit.prepared.scan(marker).size.times do
            unless source.sub!(value, '__P9999__') && translated.sub!(value, '__P9999__')
              raise TranslationValidator::Error.new(
                :nested_units, "translation changed nested token structure for #{unit.key}"
              )
            end
          end
        end
        [source, translated]
      end

      def cached_nested_markers_valid?(unit, translation)
        expected = unit.tokens.flat_map do |marker, value|
          value.scan(UNIT_MARKER) * unit.prepared.scan(marker).size
        end
        translation.scan(UNIT_MARKER).tally == expected.tally
      end

      def protected_value_counts(unit)
        unit.tokens.each_with_object(Hash.new(0)) do |(marker, value), counts|
          counts[value] += unit.prepared.scan(marker).size
        end
      end

      def preserve_entities(value)
        value.gsub(ESCAPED_ENTITY, '&')
      end
    end
  end
end
