require 'cgi'

module Ewprs
  class TranslationBatch
    module TranslationRestoration
      include EditorialStructure
      include TargetNormalization
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

      def project_mistaken_quoted_letter_tags(output)
        project_broken_quotes(output)
      end

      QUOTE_TRANSPORT = %r{
        (?:&lt;|</?)?[A-Za-z]?ewprs-(?:(?:single-)?quote-(?:open|close))
        (?:\s+id\s*=\s*(?:&quot;|["'])?\d+(?:&quot;|["'])?)?
        \s*(?:/>|/?>|&gt;|/&gt;)?
      }ix

      def project_broken_quotes(output)
        output.to_s
          .gsub(/(<|&lt;)([A-Za-z])(?=ewprs-(?:(?:single-)?quote-(?:open|close)))/i, '\1\2>')
          .gsub(QUOTE_TRANSPORT, '')
          .gsub(/<(?=[A-Za-z](?:&(?:rdquo|rsquo);|[”’]))/, '&ldquo;')
          .gsub(/&(l|r)([sd])quo(?!;)/i, '&\1\2quo;')
      end

      CJK_WORK_TITLE = /
        \b(?:The|A|An)\s+[A-Z][A-Za-z'’:-]*
        (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|with|[A-Z][A-Za-z'’:-]*))+
      /x
      CJK_TITLE_CASE = /
        \b[A-Z][A-Za-z'’:-]*
        (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|with|[A-Z][A-Za-z'’:-]*)){4,}
      /x

      def project_cjk_work_titles(unit, output)
        return output unless TranslationValidator::CJK_TARGET.key?(target)
        return output unless output.match?(TranslationValidator::CJK_SCRIPT)

        titles = "#{unit.source} #{unit.prepared}".scan(Regexp.union(CJK_WORK_TITLE, CJK_TITLE_CASE))
        titles = titles.uniq.sort_by { |title| -title.size }
        titles.reduce(output.to_s) do |projected, title|
          next projected if projected.match?(/『#{Regexp.escape(title)}』/)

          wrapped = "『#{title}』"
          projected = projected.gsub(/&ldquo;#{Regexp.escape(title)}[.,;:]?&rdquo;/, wrapped)
          projected = projected.gsub(/“#{Regexp.escape(title)}[.,;:]?”/, wrapped)
          next projected if projected.include?(wrapped)
          next projected unless projected.include?(title)

          projected.gsub(title, wrapped)
        end.then { |projected| fill_cjk_empty_quotes(projected) }
      end

      def fill_cjk_empty_quotes(value)
        value.to_s.gsub(
          /「」(?<tail>と呼ばれる|という|と呼ばれて(?:いる|います))?[[:space:]]*(?:&ldquo;(?<quoted>[^&]+)&rdquo;|“(?<smart>[^”]+)”|(?<latin>[\p{Latin}\p{M}'’.-]+))/
        ) do
          inner = Regexp.last_match[:quoted] || Regexp.last_match[:smart] || Regexp.last_match[:latin]
          "「#{inner}」#{Regexp.last_match[:tail]}"
        end
      end

      def remove_duplicated_placeholders(unit, output)
        expected = unit.prepared.scan(PLACEHOLDER).tally
        seen = Hash.new(0)
        output.to_s.gsub(PLACEHOLDER) do |marker|
          seen[marker] += 1
          seen[marker] > expected.fetch(marker, 0) ? '' : marker
        end.gsub(/(?<=\S)[ \t]{2,}(?=\S)/, ' ')
      end

      def project_missing_transliterated_tokens(unit, output)
        expected = unit.prepared.scan(PLACEHOLDER).tally
        actual = output.to_s.scan(PLACEHOLDER).tally
        projected = output.to_s.dup
        missing = unit.tokens.flat_map do |marker, value|
          count = expected.fetch(marker, 0) - actual.fetch(marker, 0)
          next [] unless count.positive?

          projectable = value.gsub(UNIT_MARKER, ' ').gsub(/[\[\]{}()]/, ' ').strip
          next [] if projectable.empty? || projectable.match?(/[<>⟦⟧]/)

          visible = CGI.unescapeHTML(projectable).unicode_normalize(:nfd)
          next [] unless visible.match?(/\p{M}/u)

          [[marker, value, visible.gsub(/\p{M}/u, '')]] * count
        end
        missing.group_by { |_marker, _value, plain| plain }.each do |plain, group|
          pattern = exact_phrase_pattern(plain)
          next unless projected.scan(pattern).size == group.size

          group.sort_by { |_marker, value, _plain| -value.size }.each do |marker, _value, _plain|
            projected.sub!(pattern, marker)
          end
        end
        projected
      end

      def project_missing_token_values(unit, output)
        expected = unit.prepared.scan(PLACEHOLDER).tally
        actual = output.to_s.scan(PLACEHOLDER).tally
        values = repair_token_values(unit.tokens)
        unit.tokens.each_with_object(output.to_s.dup) do |(marker, _value), projected|
          missing = expected.fetch(marker, 0) - actual.fetch(marker, 0)
          next unless missing.positive?

          pattern = exact_phrase_pattern(values.fetch(marker))
          next unless projected.scan(pattern).size == missing

          missing.times { projected.sub!(pattern, marker) }
        end
      end

      def project_introduced_delimiters(source, output)
        TranslationValidator::DELIMITER_PAIRS.each_with_object(output.to_s.dup) do |(opening, closing), projected|
          next unless source.to_s.count(opening).zero? && source.to_s.count(closing).zero?

          depth = 0
          balanced = projected.each_char.all? do |character|
            depth += 1 if character == opening
            depth -= 1 if character == closing
            depth >= 0
          end && depth.zero?
          projected.delete!(opening + closing) if balanced
        end
      end

      def project_missing_editorial_tags(unit, output)
        editorials = unit.prepared.scan(%r{(<span data-ewprs="[12][12]">)(.*?)</span>}mi)
        return if editorials.empty?

        untagged = output.gsub(EDITORIAL_TAG, '').gsub(/[ \t]{2,}/, ' ')
        editorials.each_with_object(untagged) do |(opening, source), projected|
          target = Array(
            translator.translate_markup([source], from: source_language, to: self.target)
          ).first.to_s.strip
          return if target.empty?

          pattern = exact_phrase_pattern(target)
          return unless projected.scan(pattern).size == 1

          projected.sub!(pattern) { "#{opening}#{Regexp.last_match[0]}</span>" }
        end
      end

      def repair_token_values(tokens)
        tokens.transform_values do |value|
          value.gsub(UNIT_MARKER) { @units.fetch(Regexp.last_match(1)).source }
        end
      end

      def placeholder_projection_values(tokens)
        expanded = repair_token_values(tokens)
        tokens.to_h do |marker, value|
          next [marker, expanded.fetch(marker)] unless value.match?(UNIT_MARKER)

          outer = value.gsub(UNIT_MARKER, '')
          visible = CGI.unescapeHTML(outer.gsub(MARKUP, ' '))
          [marker, visible.match?(/[\p{L}\p{N}]/u) ? outer : '']
        end
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
