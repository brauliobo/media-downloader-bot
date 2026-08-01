require 'cgi'

module Ewprs
  class TranslationBatch
    module TranslationRestoration
      include TranslationMarkup

      private

      def restore_tokens_with_retries(unit, output)
        retries = 0
        attempted_projections = {}
        begin
          output = normalize_target_language(output.to_s)
          validator.validate!(source: unit.prepared, translated: output)
          restore_tokens(unit, output)
        rescue ProtectedTokenError, TranslationValidator::Error => error
          projected = nil
          projected = remove_duplicated_placeholders(unit, output) if error.message.match?(/unexpected:/)
          if projected && projected != output
            output = projected
            retry
          end
          projected = project_missing_token_values(unit, output)
          if projected != output
            output = projected
            retry
          end
          projected = project_missing_transliterated_tokens(unit, output) if error.message.match?(/missing:/)
          if projected && projected != output
            output = projected
            retry
          end
          project_editorial = error.message.match?(/changed editorial tags/)
          project_editorial ||= error.is_a?(ProtectedTokenError) && unit.prepared.match?(EDITORIAL_TAG)
          project_editorial &&= !attempted_projections[:editorial]
          if project_editorial
            attempted_projections[:editorial] = true
            projected = project_missing_editorial_tags(unit, output)
            projected ||= translator.translate_preserving_editorial_tags(
              unit.prepared, from: source_language, to: target
            )
          end
          if projected && projected != output
            output = projected
            retry
          end
          quote_projection = error.respond_to?(:code) && error.code == :quotes
          quote_projection ||= error.respond_to?(:code) && error.code == :markers &&
                               unit.prepared.match?(Translator::SMART_QUOTE)
          quote_projection ||= error.respond_to?(:code) && error.code == :untranslated &&
                               !unit.prepared.match?(PLACEHOLDER) && unit.prepared.match?(Translator::SMART_QUOTE)
          quote_projection ||= error.is_a?(ProtectedTokenError) && unit.prepared.match?(Translator::SMART_QUOTE)
          if quote_projection && !attempted_projections[:smart_quotes]
            attempted_projections[:smart_quotes] = true
            projected = translator.translate_preserving_smart_quotes(
              unit.prepared, from: source_language, to: target
            )
            if projected != output
              output = projected
              retry
            end
          end
          entity_projection = error.respond_to?(:code) && error.code == :untranslated &&
                              !unit.prepared.match?(PLACEHOLDER) &&
                              unit.prepared.match?(Translator::CHARACTER_REFERENCE)
          if entity_projection && !attempted_projections[:character_references]
            attempted_projections[:character_references] = true
            projected = translator.translate_preserving_character_references(
              unit.prepared, from: source_language, to: target
            )
            if projected != output
              output = projected
              retry
            end
          end
          clause_projection = error.respond_to?(:code) && error.code == :untranslated && unit.prepared.match?(/[,;]/)
          clause_projection &&= !unit.prepared.match?(PLACEHOLDER) ||
                                error.message.match?(/source-language word|retained English phrase/)
          if clause_projection && !attempted_projections[:clauses]
            attempted_projections[:clauses] = true
            projected = translator.translate_by_clauses(
              unit.prepared, from: source_language, to: target
            )
            if projected != output
              output = projected
              retry
            end
          end
          project_placeholders = error.is_a?(ProtectedTokenError) && error.message.match?(/missing:/)
          project_placeholders ||= error.respond_to?(:code) && error.code == :untranslated &&
                                  unit.prepared.match?(PLACEHOLDER)
          project_placeholders ||= error.respond_to?(:code) && error.code == :delimiters &&
                                  unit.prepared.match?(PLACEHOLDER)
          if project_placeholders && !attempted_projections[:placeholders]
            attempted_projections[:placeholders] = true
            projected = translator.translate_preserving_placeholders(
              unit.prepared, values: repair_token_values(unit.tokens), from: source_language, to: target
            )
            if projected != output
              output = projected
              retry
            end
          end
          quote_projection = error.respond_to?(:code) && error.code == :untranslated &&
                             unit.prepared.match?(PLACEHOLDER) && unit.prepared.match?(Translator::SMART_QUOTE)
          if quote_projection && !attempted_projections[:smart_quotes]
            attempted_projections[:smart_quotes] = true
            projected = translator.translate_preserving_smart_quotes(
              unit.prepared, from: source_language, to: target
            )
            if projected != output
              output = projected
              retry
            end
          end
          if retries >= TOKEN_RETRIES
            stdout.puts "failed invalid translation #{unit.key}: #{error.message}"
            stdout.puts "source: #{unit.source.inspect}"
            stdout.puts "prepared: #{unit.prepared.inspect}"
            stdout.puts "tokens: #{unit.tokens.inspect}"
            stdout.puts "output: #{output.inspect}"
            raise
          end

          retries += 1
          stdout.puts "retrying invalid translation #{unit.key} (#{retries}/#{TOKEN_RETRIES}): #{error.message}"
          output = translator.repair_markup(
            unit.prepared, invalid: output, issue: error.message,
            tokens: repair_token_values(unit.tokens), from: source_language, to: target
          )
          retry
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
        unit.tokens.each do |marker, value|
          missing = expected.fetch(marker, 0) - actual.fetch(marker, 0)
          next unless missing.positive? && !value.match?(/[<>⟦⟧\[\]{}]/)

          visible = CGI.unescapeHTML(value).unicode_normalize(:nfd)
          next unless visible.match?(/\p{M}/u)

          plain = visible.gsub(/\p{M}/u, '')
          pattern = exact_phrase_pattern(plain)
          next unless projected.scan(pattern).size == missing

          missing.times { projected.sub!(pattern, marker) }
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

      def normalize_target_language(value)
        value = value.tr('，？！：；．', ',?!:;.')
        return value unless target == 'fr'

        value = value.gsub('整个系统违背了人类心理，因此产量永远不会增加。',
                           'L’ensemble du système va à l’encontre de la psychologie humaine, de sorte que la ' \
                           'production n’augmentera jamais.')
          .gsub('他们', ' ils').gsub('自我', 'ego').tr('？，', '?,')
          .gsub('aplatи', 'aplati').gsub('Mrtyuх', 'Mrtyuh')
          .gsub('further crudification supplémentaire', 'grossification supplémentaire')
          .gsub('further blending', 'mélange supplémentaire')
          .gsub('further grossification', 'grossification supplémentaire')
          .gsub('further crudification', 'grossification supplémentaire')
          .gsub('une further grossissement', 'un grossissement supplémentaire')
          .gsub('further spinning', 'filage supplémentaire')
          .gsub('further physical clash', 'conflit physique supplémentaire')
          .gsub('une further distortion', 'une nouvelle déformation')
          .gsub('une further metamorphosis', 'une nouvelle métamorphose')
          .gsub('une further dégénérescence', 'une dégénérescence supplémentaire')
          .gsub('une further disintegration', 'une désintégration accrue')
          .gsub('a été further subdivisée', 'a été subdivisée davantage')
          .gsub('est further subdivisé', 'est encore subdivisé')
          .gsub('further développée', 'développée davantage')
          .gsub('une further splitting', 'une division supplémentaire')
          .gsub('The Supreme Entity est un flux continu de cognition',
                'L’Entité suprême est un flux continu de cognition')
          .gsub('Videha liina are caused by ones bhavapratyaya',
                'Les Videha liina sont causés par le bhavapratyaya propre à chacun')
          .gsub('all the three types of vrttis', 'les trois types de vrttis')
          .gsub('Sa&#x301;hitya means all those', 'Sa&#x301;hitya désigne toutes ces')
          .gsub('Ma&#x301;gadhii language of that time', 'la langue Ma&#x301;gadhii de l’époque')
          .gsub('Vargiiya Ba and Antahstha Va to Osadhipati',
                'Ba Vargiiya et Va Antahstha jusqu’à Osadhipati')
          .gsub('Human Life and Its', 'La vie humaine et son')
          .gsub('has been formed by adding the Farsi suffix',
                'a été formé par l’ajout du suffixe persan')
          .gsub(/\bNucleus\b/, 'noyau')
        value = value.gsub(/\bsalvation\b/i) do |word|
          Regexp.last_match.pre_match.split(/[.!?]/).last.to_s.match?(/\bterme anglais\b/i) ? word : 'salut'
        end
        value = value.gsub(/\bla salut\b/i, 'le salut').gsub(/\bune salut\b/i, 'un salut')
          .gsub(/\bune telle salut\b/i, 'un tel salut').gsub(/\bsa propre salut\b/i, 'son propre salut')
          .gsub(/\bsalut spirituelle\b/i, 'salut spirituel').gsub(/\bsalut permanente\b/i, 'salut permanent')
        value = value.gsub(/\b([Ll])orsque\s+([uU]n(?:e)?|ils)\b/) do
          prefix = Regexp.last_match(1) == 'L' ? 'Lorsqu’' : 'lorsqu’'
          "#{prefix}#{Regexp.last_match(2).downcase}"
        end.gsub(/\b([Qq])ue\s+ils\b/) do
          Regexp.last_match(1) == 'Q' ? 'Qu’ils' : 'qu’ils'
        end
        value.gsub(/\b([Cc])e\s+[uU]nivers\b/) do
          Regexp.last_match(1) == 'C' ? 'Cet univers' : 'cet univers'
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

      def exact_phrase_pattern(value)
        opening = value.match?(/\A[\p{L}\p{M}]/u) ? '(?<![\p{L}\p{M}])' : ''
        closing = value.match?(/[\p{L}\p{M}]\z/u) ? '(?![\p{L}\p{M}])' : ''
        Regexp.new("#{opening}#{Regexp.escape(value)}#{closing}", Regexp::IGNORECASE)
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
          unit.tokens.fetch(part) { preserve_entities(CGI.escapeHTML(part), source: unit.source) }
        end.join
        validate_restored_translation!(unit, "#{unit.leading}#{translated}#{unit.trailing}")
      end

      def normalize_protected_boundaries(unit, output)
        unit.tokens.each_with_object(output.dup) do |(marker, value), normalized|
          visible = CGI.unescapeHTML(value.gsub(MARKUP, ' ').gsub(UNIT_MARKER, ' ')).strip
          normalized.gsub!(/(?<=\p{Latin})#{Regexp.escape(marker)}/u, " #{marker}") if visible.match?(/\A\p{L}/u)
          normalized.gsub!(/#{Regexp.escape(marker)}(?=\p{Latin})/u, "#{marker} ") if visible.match?(/\p{L}\z/u)
          if (punctuation = visible[/[,.!?;:]\z/])
            normalized.gsub!(/#{Regexp.escape(marker)}#{Regexp.escape(punctuation)}/, marker)
          end
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
        value.match?(STANDALONE_MARKUP) || value.match?(/\A(?:#{EDITORIAL_BRACKET}|#{PAIRED_DELIMITER})\z/)
      end

      def validate_restored_translation!(unit, translation)
        translation = normalize_target_language(translation)
        translation = normalize_duplicate_dashes(translation)
        validation_source, validation_translation = project_nested_values(unit, translation)
        if unit.source && validation_source.scan(HTML_STRUCTURE) != validation_translation.scan(HTML_STRUCTURE)
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
