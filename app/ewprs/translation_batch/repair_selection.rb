module Ewprs
  class TranslationBatch
    # Which repair a failed translation asks for, and the retry that makes it.
    module RepairSelection
      include TranslationMarkup

      private

      # Which repair each kind of failure asks for. Every one is a question about the unit and
      # the error only, so the retry loop below stays the one place that changes the output.
      def editorial_projection?(unit, error)
        error.message.match?(/changed editorial tags|changed editorial brackets/) ||
          (error.is_a?(ProtectedTokenError) && unit.prepared.match?(EDITORIAL_TAG))
      end

      def untranslated_editorial?(unit, error)
        unit.prepared.match?(EDITORIAL_TAG) && %i[untranslated target_language].include?(error.code)
      end

      def smart_quote_projection?(unit, error)
        return true if error.code == :quotes
        return false unless unit.prepared.match?(Translator::SMART_QUOTE)
        return true if error.code == :markers || error.is_a?(ProtectedTokenError)

        error.code == :untranslated && !unit.prepared.match?(PLACEHOLDER)
      end

      def placeholder_smart_quote_projection?(unit, error)
        error.code == :untranslated &&
          unit.prepared.match?(PLACEHOLDER) && unit.prepared.match?(Translator::SMART_QUOTE)
      end

      def character_reference_projection?(unit, error)
        error.code == :untranslated &&
          !unit.prepared.match?(PLACEHOLDER) && unit.prepared.match?(Translator::CHARACTER_REFERENCE)
      end

      def clause_projection?(unit, error)
        return false unless %i[untranslated target_language].include?(error.code) && unit.prepared.match?(/\s/)

        !unit.prepared.match?(PLACEHOLDER) ||
          error.message.match?(/source-language word|retained English phrase/) ||
          unit.prepared.match?(%r{[ \t]/[ \t]})
      end

      def placeholder_order_projection?(unit, error)
        return true if error.is_a?(ProtectedTokenError) && error.message.match?(/reordered structural tokens/)

        error.code == :delimiters && unit.tokens.any? { |_marker, value| nested_editorial_token?(value) }
      end

      def placeholder_projection?(unit, error)
        return true if error.is_a?(ProtectedTokenError) && error.message.match?(/missing:/)
        return true if %i[untranslated delimiters markers target_language].include?(error.code) &&
          unit.prepared.match?(PLACEHOLDER)

        placeholder_order_projection?(unit, error)
      end

      # The first repair that changes the output, cheapest first: local rewrites of the text, then
      # asking the translator again with a constraint, each constraint at most once per unit.
      def repair(unit, output, error, attempted)
        steps = [
          -> { project_mistaken_quoted_letter_tags(output) if error.code == :quotes },
          -> { remove_duplicated_placeholders(unit, output) if error.message.match?(/unexpected:/) },
          -> { project_missing_token_values(unit, output) },
          -> { project_missing_transliterated_tokens(unit, output) if error.message.match?(/missing:/) },
          -> { project_introduced_delimiters(unit.prepared, output) if error.code == :delimiters },
          -> { repair_editorial(unit, output, error, attempted) },
          -> { retranslate_once(attempted, :smart_quotes, smart_quote_projection?(unit, error), :translate_preserving_smart_quotes, unit) },
          -> { retranslate_once(attempted, :character_references, character_reference_projection?(unit, error), :translate_preserving_character_references, unit) },
          -> { retranslate_once(attempted, :clauses, clause_projection?(unit, error), :translate_by_clauses, unit) },
          -> { repair_placeholders(unit, error, attempted) },
          -> { retranslate_once(attempted, :smart_quotes, placeholder_smart_quote_projection?(unit, error), :translate_preserving_smart_quotes, unit) },
        ]
        steps.each do |step|
          projected = step.call
          return projected if projected && projected != output
        end
        output
      end

      def repair_editorial(unit, output, error, attempted)
        project_editorial = editorial_projection?(unit, error)
        if (project_editorial || untranslated_editorial?(unit, error)) && TranslationValidator::CJK_TARGET.key?(target) &&
           attempted.add?(:editorial_segments)
          retranslate(:translate_preserving_editorial_tags, unit)
        elsif project_editorial && attempted.add?(:editorial)
          project_missing_editorial_tags(unit, output) || retranslate(:translate_preserving_editorial_tags, unit)
        end
      end

      def repair_placeholders(unit, error, attempted)
        keep_order = placeholder_order_projection?(unit, error)
        return unless placeholder_projection?(unit, error) && attempted.add?(keep_order ? :placeholder_order : :placeholders)

        if keep_order
          retranslate(:translate_preserving_placeholder_order, unit)
        else
          retranslate(:translate_preserving_placeholders, unit, values: placeholder_projection_values(unit.tokens))
        end
      end

      def retranslate_once(attempted, key, applies, method, unit)
        retranslate(method, unit) if applies && attempted.add?(key)
      end

      def retranslate(method, unit, **options)
        translator.public_send(method, unit.prepared, **options, from: source_language, to: target)
      end

      def report_failure(unit, output, error)
        stdout.puts "failed invalid translation #{unit.key}: #{error.message}"
        stdout.puts "source: #{unit.source.inspect}"
        stdout.puts "prepared: #{unit.prepared.inspect}"
        stdout.puts "tokens: #{unit.tokens.inspect}"
        stdout.puts "output: #{output.inspect}"
      end
    end
  end
end
