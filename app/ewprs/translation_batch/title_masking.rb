module Ewprs
  class TranslationBatch
    # Titles of works and quoted examples are masked, so they stay as the source wrote them.
    module TitleMasking
      include TranslationMarkup

      CITED_TITLES = [
        PARTED_PUBLICATION_TITLE, DATED_PUBLICATION_TITLE, QUOTED_CITED_TITLE, QUOTED_NUMBERED_CITED_TITLE,
        NUMBERED_PUBLICATION_CITATION_TITLE, UNDATED_NUMBERED_PUBLICATION_TITLE, RELATIVE_DATED_PUBLICATION_TITLE,
        STANDALONE_NUMBERED_TITLE
      ].freeze

      PUBLICATION_TITLES = [
        NUMBERED_SERIES_TITLE, ITALIC_PART_TITLE, ITALIC_CITATION_TITLE, ITALIC_EDITION_TITLE, BOOK_TITLE,
        SEE_PARENTHETICAL_TITLE, EDITIONED_TITLE, PRINTED_EDITION_TITLE, VOLUME_CITATION_TITLE, PUBLICATION_LIST,
        MAGAZINE_LIST
      ].freeze

      BIBLIOGRAPHIC_TITLES = [BIBLIOGRAPHIC_TITLE, AUTHORED_CITATION_TITLE, UNQUOTED_PUBLICATION_TITLE].freeze

      private

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

      def mask_translation_publications(source, tokens)
        masked = source.gsub(PAIRED_TRANSLATION_PUBLICATIONS) do
          prefix, first, connector, second = Regexp.last_match.values_at(:prefix, :first, :connector, :second)
          first_marker = format('__P%04d__', tokens.size + 1)
          tokens[first_marker] = first
          second_marker = format('__P%04d__', tokens.size + 1)
          tokens[second_marker] = second
          "#{prefix}#{first_marker}#{connector}#{second_marker}"
        end
        masked.gsub(LATER_TRANSLATION_PUBLICATION) do
          prefix, title = Regexp.last_match.values_at(:prefix, :title)
          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = title
          "#{prefix}#{marker}"
        end
      end

      def mask_chapter_source_publications(source, tokens)
        source.gsub(CHAPTER_SOURCE_PUBLICATION) do
          prefix, title = Regexp.last_match.values_at(:prefix, :title)
          chapter_context = prefix.match?(/\Achapter/i) ||
                            Regexp.last_match.pre_match.match?(/\bchapters?\b[^.;]{0,80}\z/i)
          next Regexp.last_match[0] unless chapter_context

          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = title
          "#{prefix}#{marker}"
        end
      end

      def mask_quoted_publication_aliases(source, tokens)
        source.gsub(QUOTED_PUBLICATION_ALIAS) do
          original, connector, title = Regexp.last_match.values_at(:original, :connector, :title)
          original_marker = format('__P%04d__', tokens.size + 1)
          tokens[original_marker] = original
          title_marker = format('__P%04d__', tokens.size + 1)
          tokens[title_marker] = title
          "#{original_marker}#{connector}#{title_marker}"
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
          publication_context = preceding.match?(/\b(?:discourses?|published|title)\b[^.!?]{0,500}\z/i) ||
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
          next match unless Regexp.last_match.pre_match.match?(/__P\d{4}__,?\s+in\s+\z/)

          marker = format('__P%04d__', tokens.size + 1)
          tokens[marker] = match
          marker
        end
      end
    end
  end
end
