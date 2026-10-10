module Ewprs
  class TranslationBatch
    # The editorial brackets and inline pairs of a unit, and whether a restored translation keeps their order,
    # nesting and adjacency.
    module EditorialStructure
      include TranslationMarkup

      private

      def valid_structural_order?(unit, expected, actual)
        expected_editorials = expected.each_with_index.filter_map do |marker, index|
          [marker, index] if nested_editorial_token?(unit.tokens.fetch(marker))
        end
        actual_editorials = actual.each_with_index.filter_map do |marker, index|
          [marker, index] if nested_editorial_token?(unit.tokens.fetch(marker))
        end
        return false unless actual_editorials == expected_editorials

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

      def valid_editorial_structure?(unit, output, allow_moved_parts: true)
        return true unless unit.prepared.match?(EDITORIAL_TAG)

        expected = editorial_structure(unit.prepared, unit.tokens)
        actual = editorial_structure(output, unit.tokens)
        return true if expected == actual
        return false unless allow_moved_parts

        expected_parts = editorial_movable_parts(expected, unit.tokens)
        actual_parts = editorial_movable_parts(actual, unit.tokens)
        return false unless expected_parts.tally == actual_parts.tally

        movable = expected_parts.flat_map { |markers, _depth| markers }
        expected.reject { |part| movable.include?(part) } == actual.reject { |part| movable.include?(part) }
      end

      def editorial_movable_parts(structure, tokens)
        pairs = editorial_inline_pairs(structure, tokens).map do |opening, closing, depth|
          [[opening, closing], depth]
        end
        depths = editorial_depths(structure)
        nested = structure.each_with_index.filter_map do |part, index|
          next unless part.match?(PLACEHOLDER) && nested_editorial_token?(tokens.fetch(part))

          [[part], depths[index]]
        end
        pairs + nested
      end

      def editorial_inline_pairs(structure, tokens)
        depths = editorial_depths(structure)
        structure.each_with_index.filter_map do |part, index|
          next if part.match?(/\A<span\b/i) || part.match?(/\A<\/span\b/i)

          closing = structure[index + 1]
          next unless closing&.match?(PLACEHOLDER)

          opening_tag = tokens.fetch(part)[/\A<(i|em)\b[^>]*>\z/i, 1]
          closing_tag = tokens.fetch(closing)[/\A<\/(i|em)\s*>\z/i, 1]
          next unless opening_tag && closing_tag&.casecmp?(opening_tag)

          [part, closing, depths[index]]
        end
      end

      def editorial_depths(structure)
        depth = 0
        structure.map do |part|
          current = depth
          depth += 1 if part.match?(/\A<span\b/i)
          depth -= 1 if part.match?(/\A<\/span\b/i)
          current
        end
      end

      def editorial_structure(value, tokens)
        value.to_s.scan(/#{PLACEHOLDER}|#{EDITORIAL_TAG}/).select do |part|
          part.match?(EDITORIAL_TAG) || begin
            protected = tokens.fetch(part)
            structural_token?(protected) ||
              (protected.match?(PAIRED_DELIMITER) && !protected.match?(UNIT_MARKER))
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
        value.match?(STANDALONE_MARKUP) || value.match?(/\A(?:#{EDITORIAL_BRACKET}|#{PAIRED_DELIMITER})\z/) ||
          nested_editorial_token?(value)
      end

      def nested_editorial_token?(value)
        return true if value.match?(/\A\[\[#{UNIT_MARKER}\]\]\z/)
        return false if TranslationValidator::CJK_TARGET.key?(target)

        value.match?(UNIT_MARKER) && value.match?(EDITORIAL_BRACKET)
      end
    end
  end
end
