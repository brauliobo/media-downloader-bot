require 'cgi'
module Ewprs
  class TranslationBatch
    module UnitPreparation
      include TranslationMarkup

      private

      def english_function_word?(word)
        %w[
          a an and are as at be been but by can did do does for from had has have he her him
          his i if in is it its my not of on or our she that the their them they this to was we
          were what when which who will with would you your
        ].include?(word.downcase)
      end

      def prepare_unit(key, source)
        leading = source[/\A\s*/m]
        trailing = source[/\s*\z/m]
        core = source[leading.length, source.length - leading.length - trailing.length]
        tokens = {}
        prepared = mask_dense_parentheticals(core)
        prepared = mask_sanskrit_glosses(prepared)
        prepared = mask_parenthetical_clauses(prepared)
        prepared = tag_editorial_content(prepared, tokens)
        prepared = prepared.gsub(PROTECTED_MARKER) do |protected_marker|
          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = resolve_document_protected(protected_marker)
          marker
        end
        prepared = mask(prepared, PARTED_PUBLICATION_TITLE, tokens)
        prepared = mask(prepared, DATED_PUBLICATION_TITLE, tokens)
        prepared = mask(prepared, QUOTED_CITED_TITLE, tokens)
        prepared = mask(prepared, NUMBERED_PUBLICATION_CITATION_TITLE, tokens)
        prepared = mask_in_dated_citation_titles(prepared, tokens)
        prepared = mask(prepared, NUMBERED_SERIES_TITLE, tokens)
        prepared = mask(prepared, ITALIC_PART_TITLE, tokens)
        prepared = mask(prepared, ITALIC_CITATION_TITLE, tokens)
        prepared = mask(prepared, ITALIC_EDITION_TITLE, tokens)
        prepared = mask(prepared, BOOK_TITLE, tokens)
        prepared = mask(prepared, SEE_PARENTHETICAL_TITLE, tokens)
        prepared = mask(prepared, EDITIONED_TITLE, tokens)
        prepared = mask(prepared, PRINTED_EDITION_TITLE, tokens)
        prepared = mask(prepared, VOLUME_CITATION_TITLE, tokens)
        prepared = mask(prepared, PUBLICATION_LIST, tokens)
        prepared = mask(prepared, MAGAZINE_LIST, tokens)
        prepared = mask_foreign_inline(prepared, tokens)
        prepared = @lexicon.mask_inline(prepared, tokens)
        prepared = mask_named_marked_groups(prepared, tokens)
        prepared = mask(prepared, BIBLIOGRAPHIC_TITLE, tokens)
        prepared = mask(prepared, AUTHORED_CITATION_TITLE, tokens)
        prepared = mask(prepared, UNQUOTED_PUBLICATION_TITLE, tokens)
        prepared = mask_quoted_publication_titles(prepared, tokens)
        prepared = mask_quoted_language_examples(prepared, tokens)
        prepared = mask_title_case_quotes(prepared, tokens)
        prepared = mask(prepared, MARKUP, tokens)
        prepared = expose_editorial_tags(prepared)
        prepared = mask(prepared, EDITORIAL_BRACKET, tokens)
        prepared = mask(prepared, PAIRED_DELIMITER, tokens)
        prepared = mask(prepared, MARKED_WORD, tokens)
        prepared = mask(prepared, TECHNICAL_VALUE, tokens)
        prepared = mask(prepared, INDIC_SCRIPT, tokens)
        prepared = @lexicon.mask(prepared, tokens)
        prepared = coalesce_adjacent_terms(prepared, tokens)
        prepared = prepared.gsub(COORDINATED_PLACEHOLDER) do
          match = Regexp.last_match
          "#{match[:first]} #{match[:term]} and #{match[:second]} ones"
        end
        tokens.transform_values! do |value|
          restore_token_editorial_markers(resolve_document_protected_value(value))
        end
        prepared, tokens = canonicalize_placeholders(prepared, tokens)
        prepared = CGI.unescapeHTML(prepared)
        WINDOWS_CONTROLS.each { |from, to| prepared.gsub!(from, to) }
        missing = prepared.scan(PLACEHOLDER).uniq - tokens.keys
        raise "prepared unit #{key} has unregistered placeholders: #{missing.join(', ')}" unless missing.empty?

        Unit.new(
          key: key, source: resolve_unit_source(source), prepared: prepared, tokens: tokens,
          leading: leading, trailing: trailing
        )
      end

      def resolve_unit_source(source)
        resolved = resolve_document_protected_value(source).gsub(UNIT_MARKER) do
          @units.fetch(Regexp.last_match(1)).source
        end
        restore_token_editorial_markers(resolved)
      end

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

      def plain_protected_term?(value)
        !value.match?(/[<>⟦⟧()\[\]{}]/)
      end

      def mask_sanskrit_glosses(source)
        masked = mask_glosses(source, QUOTED_GLOSS)
        masked = mask_inline_parenthetical_glosses(masked)
        masked = mask_coordinated_with_glosses(masked)
        masked = mask_coordinated_bracketed_glosses(masked)
        masked = mask_coordinated_terms_parenthetical_gloss(masked)
        masked = mask_coordinated_parenthetical_glosses(masked)
        masked = mask_glosses(masked, @lexicon.inline_gloss_pattern)
        masked = mask_glosses(masked, MARKED_INLINE_GLOSS)
        masked = mask_glosses(masked, MARKED_PHRASE_GLOSS)
        masked = mask_glosses(masked, DEFINED_TERM_GLOSS)
        masked = mask_glosses(masked, HYPHENATED_TERM_GLOSS)
        masked = mask_glosses(masked, CONSONANT_TERM_GLOSS)
        masked = mask_glosses(masked, ASCII_PHRASE_PARENTHETICAL_GLOSS)
        masked = mask_glosses(masked, @lexicon.parenthetical_gloss_pattern)
        masked = mask_glosses(masked, @lexicon.gloss_pattern)
        mask_proper_noun_glosses(masked)
      end

      def mask_inline_parenthetical_glosses(source)
        source.gsub(INLINE_PARENTHETICAL_GLOSS) do |match|
          captures = Regexp.last_match
          next match unless translatable?(captures[:gloss])

          protect_content(
            "#{captures[:term]}#{captures[:spacing]}(#{register_unit(captures[:gloss])})"
          )
        end
      end

      def mask_coordinated_with_glosses(source)
        source.gsub(COORDINATED_WITH_GLOSSES) do
          captures = Regexp.last_match
          first = nested_bracketed_gloss(captures, :first)
          second = nested_bracketed_gloss(captures, :second)
          "#{captures[:prefix]}#{first}#{captures[:coordination]}#{second}"
        end
      end

      def mask_proper_noun_glosses(source)
        source.gsub(PROPER_NOUN_GLOSS) do |match|
          prefix, term, spacing, opening, gloss, closing = Regexp.last_match.values_at(
            :prefix, :term, :spacing, :opening, :gloss, :closing
          )
          next match if english_function_word?(term) || !translatable?(gloss)

          "#{prefix}#{protect_content("#{term}#{spacing}#{opening}#{register_unit(gloss)}#{closing}")}"
        end
      end

      def mask_coordinated_bracketed_glosses(source)
        source.gsub(COORDINATED_BRACKETED_GLOSSES) do
          captures = Regexp.last_match
          first = nested_bracketed_gloss(captures, :first)
          second = nested_bracketed_gloss(captures, :second)
          "#{first}#{captures[:coordination]}#{second}"
        end
      end

      def nested_bracketed_gloss(captures, prefix)
        term, spacing, opening, gloss, closing = %i[term spacing opening gloss closing].map do |part|
          captures["#{prefix}_#{part}".to_sym]
        end
        translated = translatable?(gloss) ? register_unit(gloss) : gloss
        protect_content("#{term}#{spacing}#{opening}#{translated}#{closing}")
      end

      def mask_coordinated_parenthetical_glosses(source)
        source.gsub(PARENTHETICAL_GLOSS_LIST) do |list|
          terms = list.to_enum(:scan, PARENTHETICAL_GLOSS).map { Regexp.last_match[:term] }
          next list unless terms.any? { |term| term.match?(MARKED_WORD) }

          list.gsub(PARENTHETICAL_GLOSS) do
            captures = Regexp.last_match
            nested_parenthetical_gloss(captures[:term], captures[:spacing], captures[:gloss])
          end
        end
      end

      def mask_coordinated_terms_parenthetical_gloss(source)
        source.gsub(COORDINATED_TERMS_PARENTHETICAL_GLOSS) do |match|
          captures = Regexp.last_match
          next match unless captures[:terms].match?(MARKED_WORD) && translatable?(captures[:gloss])
          next match if captures.post_match.match?(/\A\s+#{MARKED_WORD}/)

          protect_content(
            "#{captures[:terms]}#{captures[:spacing]}(#{register_unit(captures[:gloss])})"
          )
        end
      end

      def nested_parenthetical_gloss(term, spacing, gloss)
        translated = translatable?(gloss) ? register_unit(gloss) : gloss
        protect_content("#{term}#{spacing}(#{translated})")
      end

      def mask_dense_parentheticals(source)
        source.gsub(PARENTHETICAL_CONTENT) do |match|
          content = Regexp.last_match[:content]
          structured = content.include?('=') || content.scan(MARKED_WORD).size >= 2
          next match if !structured && content.length <= MAX_INLINE_PARENTHETICAL_CHARS

          nested = translatable?(content) ? register_unit(content) : content
          protect_content("(#{nested})")
        end
      end

      def mask_parenthetical_clauses(source)
        source.gsub(PARENTHETICAL_CONTENT) do |match|
          captures = Regexp.last_match
          content = captures[:content]
          words = CGI.unescapeHTML(content).scan(/[A-Za-z][A-Za-z'’-]*/)
          quantified_term = /\b#{QUANTIFIER}\s+[A-Za-z-]+\s+[A-Za-z'’-]+\s*\z/
          next match if words.empty? || (words.one? && words.first.length == 1)
          next match if content.match?(/[\[\]]/) || captures.pre_match.match?(quantified_term)
          next match unless translatable?(content)

          protect_content("(#{register_unit(content)})")
        end
      end

      def mask_foreign_inline(source, tokens)
        source.gsub(FOREIGN_INLINE) do |match|
          content = Regexp.last_match[:content]
          next match unless validator.protected_inline_fragment?(content)

          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = match
          marker
        end
      end

      def mask_named_marked_groups(source, tokens)
        source.gsub(NAMED_MARKED_GROUP) do |match|
          captures = Regexp.last_match
          prefix   = captures[:prefix]
          group    = CGI.unescapeHTML(captures[:group]).unicode_normalize(:nfd).gsub(/\p{M}/, '')
          next match unless group.end_with?('s')

          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = match.delete_prefix(prefix)
          "#{prefix}#{marker}"
        end
      end

      def mask_quoted_publication_titles(source, tokens)
        source.gsub(QUOTED_PUBLICATION_TITLE) do
          prefix, title = Regexp.last_match.values_at(:prefix, :title)
          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = title
          "#{prefix}#{marker}"
        end
      end

      def mask_quoted_language_examples(source, tokens)
        source.gsub(QUOTED_LANGUAGE_EXAMPLE) do
          match = Regexp.last_match
          prefix, example = match.values_at(:prefix, :example)
          if prefix.match?(/\b(?:say|says|said)\b/i)
            linguistic_context = match.pre_match.match?(
              /(?:\bIn\s+English\b|\b(?:word|phrase|sentence|expression|term|language)\b)[^.!?]{0,240}\z/i
            )
            next match[0] unless linguistic_context
          end

          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = example
          "#{prefix}#{marker}"
        end
      end

      def mask_title_case_quotes(source, tokens)
        source.gsub(QUOTED_TITLE) do |match|
          preceding = Regexp.last_match.pre_match
          following = Regexp.last_match.post_match
          provenance = following.match?(
            /\A\s+(?:(?:comes?|came)\s+from|is\s+thought\s+to\s+(?:be|have\s+come)\s+from)\b/i
          ) || (preceding.match?(/,\s+and\s+\z/i) && following.match?(/\A\s+from\b/i))
          publication_context = preceding.match?(/\b(?:discourses?|title)\b[^.!?]{0,500}\z/i) ||
            following.match?(/\A\s+had\s+appeared\b/i)
          next match unless provenance || publication_context

          plain = CGI.unescapeHTML(match.gsub(/&[a-z]+;/i, ' '))
            .unicode_normalize(:nfd).gsub(/\p{M}/, '')
          words = plain.scan(/[A-Za-z][A-Za-z'’-]*/)
          capitalized = words.count { |word| word.match?(/\A[A-Z]/) }
          title_case = words.all? do |word|
            word.match?(/\A[A-Z]/) || TITLE_CONNECTORS.include?(word.downcase)
          end
          next match unless capitalized >= 3 && title_case

          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = match
          marker
        end
      end

      def mask_in_dated_citation_titles(source, tokens)
        source.gsub(IN_DATED_CITATION_TITLE) do |match|
          next match unless Regexp.last_match.pre_match.match?(/__P\d{4}__\s+in\s+\z/)

          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = match
          marker
        end
      end

      def mask_glosses(source, pattern)
        source.gsub(pattern) do |match|
          captures = Regexp.last_match
          term, spacing, opening, gloss, closing = captures.values_at(
            :term, :spacing, :opening, :gloss, :closing
          )
          suffix = captures.names.include?('suffix') ? captures[:suffix] : nil
          next match unless translatable?(gloss)
          if pattern == @lexicon.parenthetical_gloss_pattern
            quantified = /\b#{QUANTIFIER}\s+[A-Za-z-]+\s+\z/
            next match if captures.pre_match.match?(quantified)
          end
          if pattern == MARKED_PHRASE_GLOSS
            words = CGI.unescapeHTML(term).scan(/[A-Za-z][A-Za-z'’-]*/)
            next match if words.any? { |word| english_function_word?(word) }
          end

          protect_content("#{term}#{spacing}#{opening}#{register_unit(gloss)}#{closing}#{suffix}")
        end
      end

      def tag_editorial_content(source, tokens)
        editorial_counts = source.scan(EDITORIAL_CONTENT).tally
        source = source.gsub(HYPHENATED_EDITORIAL) do |match|
          prefix, editorial = Regexp.last_match.values_at(:prefix, :editorial)
          opening, content, closing = editorial_parts(editorial)
          next match unless translatable?(content)

          depth = "#{opening.length}#{closing.length}"
          "⟦E#{depth}⟧#{prefix}-#{content}⟦/E#{depth}⟧"
        end
        source = source.gsub(ATTACHED_EDITORIAL) do |match|
          prefix, editorial = Regexp.last_match.values_at(:prefix, :editorial)
          opening, content, closing = editorial_parts(editorial)
          next match unless translatable?(content)

          depth = "#{opening.length}#{closing.length}"
          "⟦E#{depth}⟧#{prefix}#{content}⟦/E#{depth}⟧"
        end
        source.gsub(EDITORIAL_CONTENT) do
          editorial = Regexp.last_match[0]
          pre_match = Regexp.last_match.pre_match
          opening, content, closing = editorial_parts(editorial)
          if translatable?(content)
            quoted = content.match?(/\A&(?:ldquo|quot);.*&(?:rdquo|quot);\z/i)
            sentence_bearing = content.match?(/[.!?]\s+[A-Z]/) && !quoted
            plain_content = CGI.unescapeHTML(content)
            WINDOWS_CONTROLS.each { |from, to| plain_content.gsub!(from, to) }
            possessive_phrase = plain_content.match?(/[A-Za-z]+['’]s\s+[A-Za-z]/i)
            lexical_completion = content.match?(/\A[A-Za-z]+(?:['’-][A-Za-z]+)*\z/) &&
                                 pre_match.match?(/\b[a-z][A-Za-z'’-]*\s+\z/)
            if opening.length == 2 || closing.length == 2 ||
               content.length > MAX_INLINE_EDITORIAL_CHARS ||
               sentence_bearing || possessive_phrase || lexical_completion ||
               editorial_counts.fetch(editorial, 0) > 1 ||
               content.match?(/\b[A-Za-z]+-[A-Za-z]+\b/)
              next protect_content("#{opening}#{register_sentences(content)}#{closing}")
            end

            depth = "#{opening.length}#{closing.length}"
            next "⟦E#{depth}⟧#{content}⟦/E#{depth}⟧"
          end

          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = "#{opening}#{content}#{closing}"
          marker
        end
      end

      def expose_editorial_tags(source)
        source.gsub(/⟦E([12])([12])⟧/, '<span data-ewprs="\1\2">')
          .gsub(%r{⟦/E[12][12]⟧}, '</span>')
      end

      def editorial_parts(value)
        opening = value[/\A\[\[?/]
        closing = value[/\]\]?\z/]
        [opening, value[opening.length...-closing.length], closing]
      end

      def mask(value, pattern, tokens)
        value.gsub(pattern) do |match|
          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = match
          marker
        end
      end
    end
  end
end
