require 'cgi'

module Ewprs
  class TranslationBatch
    module TranslationRestoration
      include EditorialStructure
      include TargetNormalization
      include TranslationMarkup
      include RepairSelection
      include OutputProjections

      private

      def restore_tokens_with_retries(unit, output)
        attempted = Set.new
        allow_moved_editorial = output.to_s.scan(EDITORIAL_TAG) == unit.prepared.scan(EDITORIAL_TAG)
        attempt = 0
        Utils::Retry.call(tries: TOKEN_RETRIES + 1, sleep: false, on: [ProtectedTokenError, TranslationValidator::Error]) do
          attempt += 1
          begin
            output = normalize_output(unit, output)
            validator.validate!(source: unit.prepared, translated: output)
            restore_tokens(unit, output, allow_moved_editorial: allow_moved_editorial)
          rescue ProtectedTokenError, TranslationValidator::Error => error
            repaired = repair(unit, output, error, attempted)
            if repaired != output
              output = repaired
              retry
            end
            if attempt > TOKEN_RETRIES
              report_failure(unit, output, error)
              raise
            end

            stdout.puts "retrying invalid translation #{unit.key} (#{attempt}/#{TOKEN_RETRIES}): #{error.message}"
            output = translator.repair_markup(
              unit.prepared, invalid: output, issue: error.message,
              tokens: repair_token_values(unit.tokens), from: source_language, to: target
            )
            raise error
          end
        end
      end

      def normalize_output(unit, output)
        output = normalize_target_language(output.to_s)
        output = strip_introduced_foreign_scripts(unit.prepared, output)
        output = project_broken_quotes(output)
        output = project_cjk_work_titles(unit, output)
        strip_echoed_protected_ascii(unit, output)
      end

      def restore_tokens(unit, output, allow_moved_editorial: true)
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
        unless valid_editorial_structure?(unit, output, allow_moved_parts: allow_moved_editorial)
          raise ProtectedTokenError, "translation changed editorial tags for #{unit.key}"
        end

        unless valid_structural_order?(unit, expected, actual) && valid_structural_adjacency?(unit, output)
          raise ProtectedTokenError, "translation reordered structural tokens for #{unit.key}"
        end

        translated = restore_editorial_tags(output).split(/(#{PLACEHOLDER})/).map do |part|
          unit.tokens.fetch(part) { preserve_entities(CGI.escapeHTML(part), source: unit.source) }
        end.join
        translated = project_broken_quotes(translated)
        validate_restored_translation!(unit, "#{unit.leading}#{translated}#{unit.trailing}")
      end

      def normalize_protected_boundaries(unit, output)
        normalized = unit.tokens.each_with_object(output.dup) do |(marker, value), result|
          visible = CGI.unescapeHTML(value.gsub(MARKUP, ' ').gsub(UNIT_MARKER, ' ')).strip
          result.gsub!(/(?<=\p{Latin})#{Regexp.escape(marker)}/u, " #{marker}") if visible.match?(/\A\p{L}/u)
          result.gsub!(/#{Regexp.escape(marker)}(?=\p{Latin})/u, "#{marker} ") if visible.match?(/\p{L}\z/u)
          if (punctuation = visible[/[,.!?;:]\z/])
            result.gsub!(/#{Regexp.escape(marker)}#{Regexp.escape(punctuation)}/, marker)
          end
        end
        unit.prepared.scan(/(#{PLACEHOLDER})([ \t]+)(#{PLACEHOLDER})/).each do |left, spacing, right|
          left_visible  = CGI.unescapeHTML(unit.tokens.fetch(left).gsub(MARKUP, ' ').gsub(UNIT_MARKER, ' ')).strip
          right_visible = CGI.unescapeHTML(unit.tokens.fetch(right).gsub(MARKUP, ' ').gsub(UNIT_MARKER, ' ')).strip
          next unless left_visible.match?(/\p{L}\z/u) && right_visible.match?(/\A\p{L}/u)

          normalized.gsub!(/#{Regexp.escape(left)}#{Regexp.escape(right)}/, "#{left}#{spacing}#{right}")
        end
        normalized
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

      def validate_restored_translation!(unit, translation)
        translation = strip_echoed_protected_ascii(unit, translation)
        translation = normalize_target_language(translation, strip_glue: false)
        translation = normalize_duplicate_dashes(translation)
        source_structure = restore_editorial_tags(unit.prepared).gsub(PLACEHOLDER) do |marker|
          unit.tokens.fetch(marker)
        end
        if source_structure.scan(EDITORIAL_BRACKET) != translation.scan(EDITORIAL_BRACKET)
          raise TranslationValidator::Error.new(:markup, 'translation changed editorial brackets')
        end

        validation_source, validation_translation = project_nested_values(unit, translation)
        if unit.source && !html_structure_compatible?(
          validation_source, validation_translation,
          allow_moved_inline_nesting: TranslationValidator::CJK_TARGET.key?(target)
        )
          raise TranslationValidator::Error.new(:markup, 'translation changed HTML tag sequence')
        end

        protected_values = protected_value_counts(unit)
        progress_values = progress_protected_value_counts(
          protected_values, strip_nested_delimiters: unit.prepared.match?(EDITORIAL_TAG)
        )
        validator.validate!(
          source: validation_source, translated: validation_translation,
          protected_values: progress_values, protected_connectors: protected_connector_values(unit)
        )
        validator.validate_protected!(
          source: unit.source, translated: translation, protected_values: protected_values
        )
        translation
      end

      def normalize_duplicate_dashes(value)
        value.to_s.gsub(/(?:&ndash;[ \t]*[–—]|[–—][ \t]*&ndash;)/, '&ndash;')
          .gsub(/(?:&mdash;[ \t]*[–—]|[–—][ \t]*&mdash;)/, '&mdash;')
      end

      def progress_protected_value_counts(protected_values, strip_nested_delimiters: false)
        protected_values.each_with_object(Hash.new(0)) do |(value, count), projected|
          fragments = if value.match?(UNIT_MARKER)
            progress_value = if strip_nested_delimiters
              value.gsub(/(?:\((⟦U[0-9a-f]{64}⟧)\)|\[{1,2}(⟦U[0-9a-f]{64}⟧)\]{1,2}|\{(⟦U[0-9a-f]{64}⟧)\})/) do
                Regexp.last_match.captures.compact.first
              end
            else
              value
            end
            progress_value.split(/⟦U[0-9a-f]{64}⟧/, -1).reject(&:empty?)
          else
            [value]
          end
          fragments.each { |fragment| projected[fragment] += count }
        end
      end

      def protected_connector_values(unit)
        values = repair_token_values(unit.tokens)
        pattern = /(?<left>#{PLACEHOLDER})(?<punctuation>[.,;]*)\s+(?<connector>[A-Za-z]+)\s+(?<right>#{PLACEHOLDER})/
        unit.prepared.scan(pattern).map do |left, punctuation, connector, right|
          [values.fetch(left), punctuation, connector, values.fetch(right)]
        end
      end

      def project_nested_values(unit, translation)
        nested_tokens = unit.tokens.select { |_marker, value| value.match?(UNIT_MARKER) }
        return [unit.source.dup, translation.dup] if nested_tokens.empty?

        source = restore_editorial_tags(unit.prepared).gsub(PLACEHOLDER) do |marker|
          unit.tokens.fetch(marker)
        end
        translated = translation.dup
        nested_tokens.flat_map do |marker, value|
          value.to_enum(:scan, UNIT_MARKER).map { Regexp.last_match[0] } * unit.prepared.scan(marker).size
        end.each_with_index do |nested_marker, index|
          projection = format('__P%04d__', 9000 + index)
          unless source.sub!(nested_marker, projection) && translated.sub!(nested_marker, projection)
            raise TranslationValidator::Error.new(
              :nested_units, "translation changed nested token structure for #{unit.key}"
            )
          end
        end
        if unit.prepared.match?(EDITORIAL_TAG)
          nested_delimiters = /(?:\((__P9\d{3}__)\)|\[{1,2}(__P9\d{3}__)\]{1,2}|\{(__P9\d{3}__)\})/
          source.gsub!(nested_delimiters) { Regexp.last_match.captures.compact.first }
          translated.gsub!(nested_delimiters) { Regexp.last_match.captures.compact.first }
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

      def preserve_entities(value, source: nil)
        preserved = value.gsub(ESCAPED_ENTITY, '&')
        source.to_s.scan(/&(?:#\d+|#x[\da-f]+|[a-z][\w]+);?/i).uniq.each do |reference|
          preserved.gsub!(CGI.escapeHTML(reference), reference)
        end
        preserved
      end
    end
  end
end
