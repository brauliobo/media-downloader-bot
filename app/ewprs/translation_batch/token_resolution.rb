module Ewprs
  class TranslationBatch
    # Masked values are folded into each other and given their final placeholders.
    module TokenResolution
      include TranslationMarkup

      private

      def canonicalize_placeholders(source, tokens)
        ordered = source.scan(PLACEHOLDER).uniq
        reachable = ordered.dup
        reachable.each do |marker|
          tokens.fetch(marker).scan(PLACEHOLDER).each do |nested|
            reachable << nested unless reachable.include?(nested)
          end
        end
        unused = tokens.keys - reachable
        raise "prepared unit has unused placeholders: #{unused.join(', ')}" unless unused.empty?

        resolved = ordered.to_h { |marker| [marker, resolve_token_value(marker, tokens)] }
        replacements = ordered.each_with_index.to_h do |marker, index|
          [marker, format('__P%04d__', index + 1)]
        end
        prepared = source.gsub(PLACEHOLDER) { |marker| replacements.fetch(marker) }
        canonical = ordered.to_h do |marker|
          [replacements.fetch(marker), resolved.fetch(marker)]
        end
        [prepared, canonical]
      end

      def resolve_document_protected(marker, stack = [])
        raise "cyclic document protection: #{[*stack, marker].join(' -> ')}" if stack.include?(marker)

        resolve_document_protected_value(@document_protected.fetch(marker), [*stack, marker])
      end

      def resolve_document_protected_value(value, stack = [])
        value.gsub(PROTECTED_MARKER) { |nested| resolve_document_protected(nested, stack) }
      end

      def restore_token_editorial_markers(value)
        value.gsub(/⟦E([12])([12])⟧/) { '[' * Regexp.last_match(1).to_i }
          .gsub(%r{⟦/E([12])([12])⟧}) { ']' * Regexp.last_match(2).to_i }
      end

      def resolve_token_value(marker, tokens, stack = [])
        raise "cyclic protected placeholders: #{[*stack, marker].join(' -> ')}" if stack.include?(marker)

        tokens.fetch(marker).gsub(PLACEHOLDER) do |nested|
          resolve_token_value(nested, tokens, [*stack, marker])
        end
      end

      def coalesce_adjacent_terms(source, tokens)
        loop do
          changed = false
          source = source.gsub(ADJACENT_PROTECTED_TERMS) do |match|
            left, spacing, right = Regexp.last_match.values_at(:left, :spacing, :right)
            if plain_protected_term?(tokens.fetch(left)) && plain_protected_term?(tokens.fetch(right))
              tokens[left] = "#{tokens.fetch(left)}#{spacing}#{tokens.delete(right)}"
              changed = true
              left
            else
              match
            end
          end
          return source unless changed
        end
      end

      def coalesce_inline_punctuation(source, tokens)
        pattern = /(?<term>#{PLACEHOLDER})(?<opening>#{PLACEHOLDER})(?<punctuation>[,;:])(?<closing>#{PLACEHOLDER})/
        source.gsub(pattern) do |match|
          captures = Regexp.last_match
          term, opening, closing = captures.values_at(:term, :opening, :closing)
          opening_tag = tokens.fetch(opening)[/\A<(i|em)\b[^>]*>\z/i, 1]
          closing_tag = tokens.fetch(closing)[/\A<\/(i|em)\s*>\z/i, 1]
          next match unless plain_protected_term?(tokens.fetch(term)) && opening_tag&.casecmp?(closing_tag)

          tokens[term] = "#{tokens.fetch(term)}#{tokens.delete(opening)}" \
                         "#{captures[:punctuation]}#{tokens.delete(closing)}"
          term
        end
      end

      def nest_repeated_term_modifiers(source, tokens)
        repeated_values = tokens.values.tally.select do |value, count|
          count > 1 && plain_protected_term?(value)
        end.keys.to_h { |value| [value, true] }
        modifier_pattern = /(?<![;'’])\b(?<modifier>[A-Za-z][A-Za-z'’-]*)\s+(?<marker>#{PLACEHOLDER})/
        matches = source.to_enum(:scan, modifier_pattern)
          .map { Regexp.last_match.named_captures }
        matched_markers = matches.group_by { |match| tokens.fetch(match.fetch('marker')) }
        eligible = repeated_values.select do |value, _present|
          markers = tokens.select { |_marker, token| token == value }.keys
          matched = matched_markers.fetch(value, []).map { |match| match.fetch('marker') }
          matched.sort == markers.sort
        end
        return source if eligible.empty?

        source.gsub(modifier_pattern) do |match|
          captures = Regexp.last_match
          marker = captures[:marker]
          next match unless eligible.key?(tokens.fetch(marker)) && !english_function_word?(captures[:modifier])

          tokens[marker] = "#{register_unit(captures[:modifier])} #{tokens.fetch(marker)}"
          marker
        end
      end

      def nest_coordinated_term_definitions(source, tokens)
        pattern = /(?<marker>#{PLACEHOLDER})\s+or\s+(?<gloss>[A-Za-z][A-Za-z'’ -]*?)(?=\s*(?:,|\band\b|[:.;]|\z))/
        source.gsub(pattern) do
          captures = Regexp.last_match
          marker = captures[:marker]
          tokens[marker] = "#{tokens.fetch(marker)} #{register_unit("or #{captures[:gloss].strip}")}"
          marker
        end
      end

      def plain_protected_term?(value)
        !value.match?(/[<>⟦⟧()\[\]{}]/)
      end

      def resolve_unit_source(source)
        resolved = resolve_document_protected_value(source).gsub(UNIT_MARKER) do
          @units.fetch(Regexp.last_match(1)).source
        end
        restore_token_editorial_markers(resolved)
      end
    end
  end
end
