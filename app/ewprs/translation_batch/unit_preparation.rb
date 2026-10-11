require 'cgi'

module Ewprs
  class TranslationBatch
    module UnitPreparation
      include TranslationMarkup
      include GlossMasking
      include TitleMasking
      include TokenResolution

      STRUCTURAL_VALUES    = [EDITORIAL_BRACKET, PAIRED_DELIMITER, MARKED_WORD, TECHNICAL_VALUE, INDIC_SCRIPT].freeze

      private

      def prepare_unit(key, source)
        leading = source[/\A\s*/m]
        trailing = source[/\s*\z/m]
        core = source[leading.length, source.length - leading.length - trailing.length]
        tokens = {}
        prepared = mask_titles_and_terms(rewrite_attached_words(core), tokens)
        prepared = mask_markup(prepared, tokens)
        prepared = coalesce_terms(prepared, tokens)
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

      def rewrite_attached_words(text)
        mask_parenthetical_clauses(mask_sanskrit_glosses(mask_dense_parentheticals(
          mask_parenthetical_foreign_equivalents(separate_attached_source_words(text))
        )))
      end

      # Titles are masked from the most specific shape to the loosest, so a title that fits two
      # patterns is taken by the first; the order below is the order they are tried in.
      def mask_titles_and_terms(text, tokens)
        prepared = tag_editorial_content(text, tokens)
        prepared = prepared.gsub(PROTECTED_MARKER) do |protected_marker|
          register_token(tokens, resolve_document_protected(protected_marker))
        end
        prepared = mask_each(prepared, tokens, CITED_TITLES)
        prepared = mask_in_dated_citation_titles(prepared, tokens)
        prepared = mask_each(prepared, tokens, PUBLICATION_TITLES)
        prepared = mask_foreign_inline(prepared, tokens)
        prepared = @lexicon.mask_inline(prepared, tokens)
        prepared = mask_named_marked_groups(prepared, tokens)
        prepared = mask_each(prepared, tokens, BIBLIOGRAPHIC_TITLES)
        prepared = mask_chapter_source_publications(prepared, tokens)
        prepared = mask_translation_publications(prepared, tokens)
        prepared = mask_quoted_publication_titles(prepared, tokens)
        prepared = mask_quoted_publication_aliases(prepared, tokens)
        prepared = mask_quoted_language_examples(prepared, tokens)
        mask_title_case_quotes(prepared, tokens)
      end

      def mask_markup(text, tokens)
        prepared = mask(text, MARKUP, tokens)
        prepared = expose_editorial_tags(prepared)
        prepared = mask_each(prepared, tokens, STRUCTURAL_VALUES)
        @lexicon.mask(prepared, tokens)
      end

      def coalesce_terms(text, tokens)
        prepared = coalesce_adjacent_terms(coalesce_inline_punctuation(text, tokens), tokens)
        prepared = prepared.gsub(COORDINATED_PLACEHOLDER) do
          match = Regexp.last_match
          "#{match[:first]} #{match[:term]} and #{match[:second]} ones"
        end
        nest_repeated_term_modifiers(nest_coordinated_term_definitions(prepared, tokens), tokens)
      end

      def mask_each(text, tokens, patterns)
        patterns.reduce(text) { |masked, pattern| mask(masked, pattern, tokens) }
      end

      def tag_editorial_content(source, tokens)
        editorial_counts = source.scan(EDITORIAL_CONTENT).tally
        source = tag_attached_editorial(source, HYPHENATED_EDITORIAL, '-')
        source = tag_attached_editorial(source, ATTACHED_EDITORIAL, '')
        source.gsub(EDITORIAL_CONTENT) do
          editorial = Regexp.last_match[0]
          tag_editorial(editorial, Regexp.last_match.pre_match, editorial_counts, tokens)
        end
      end

      # An editorial insertion glued to the word before it, with or without a hyphen.
      def tag_attached_editorial(source, pattern, joiner)
        source.gsub(pattern) do |match|
          prefix, editorial = Regexp.last_match.values_at(:prefix, :editorial)
          opening, content, closing = editorial_parts(editorial)
          next match unless translatable?(content)

          editorial_span(opening, closing, "#{prefix}#{joiner}#{content}")
        end
      end

      def tag_editorial(editorial, pre_match, editorial_counts, tokens)
        opening, content, closing = editorial_parts(editorial)
        return register_token(tokens, editorial) unless translatable?(content)
        return editorial_span(opening, closing, content) unless protected_editorial?(editorial, pre_match, editorial_counts)

        protect_content("#{opening}#{register_sentences(content)}#{closing}")
      end

      def editorial_span(opening, closing, text)
        depth = "#{opening.length}#{closing.length}"
        "⟦E#{depth}⟧#{text}⟦/E#{depth}⟧"
      end

      # Insertions that read as text of their own, not as a gloss on the words around them.
      def protected_editorial?(editorial, pre_match, editorial_counts)
        opening, content, closing = editorial_parts(editorial)
        quoted           = content.match?(/\A&(?:ldquo|quot);.*&(?:rdquo|quot);\z/i)
        sentence_bearing = content.match?(/[.!?]\s+[A-Z]/) && !quoted
        plain_content    = CGI.unescapeHTML(content)
        WINDOWS_CONTROLS.each { |from, to| plain_content.gsub!(from, to) }
        possessive_phrase  = plain_content.match?(/[A-Za-z]+['’]s\s+[A-Za-z]/i)
        lexical_completion = content.match?(/\A[A-Za-z]+(?:['’-][A-Za-z]+)*\z/) &&
                             pre_match.match?(/\b[a-z][A-Za-z'’-]*\s+\z/)
        opening.length == 2 || closing.length == 2 ||
          content.length > MAX_INLINE_EDITORIAL_CHARS ||
          sentence_bearing || possessive_phrase || lexical_completion ||
          editorial_counts.fetch(editorial, 0) > 1 ||
          content.match?(/\b[A-Za-z]+-[A-Za-z]+\b/)
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
          register_token(tokens, match)
        end
      end
    end
  end
end
