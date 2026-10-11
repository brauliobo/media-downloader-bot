module Ewprs
  class TranslationBatch
    # Mistakes a model makes in the output that can be put right without asking again.
    module OutputProjections
      include TranslationMarkup

      private

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
    end
  end
end
