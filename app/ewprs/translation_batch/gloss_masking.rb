module Ewprs
  class TranslationBatch
    # Glosses and parentheticals that follow a foreign term are masked with the term, so the model sees one unit.
    module GlossMasking
      include TranslationMarkup

      ATTACHED_SOURCE_WORD = %r{
        (?<term>(?<![A-Za-z])[A-Za-z][A-Za-z'’-]*
        (?:(?:&\#x(?:301|32D);)[A-Za-z'’-]*)+?)-?
        (?<word>descended|respectively|those)(?![A-Za-z])
      }ix

      private

      def english_function_word?(word)
        %w[
          a an and are as at be been but by can did do does for from had has have he her him
           his i if in is it its my not of on or our she that the their them they this to was we
           were what when which who will with would you your means
        ].include?(word.downcase)
      end

      def separate_attached_source_words(source)
        source.gsub(ATTACHED_SOURCE_WORD) do
          captures = Regexp.last_match
          "#{captures[:term].delete_suffix('-')} #{captures[:word]}"
        end
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
        masked = mask_glosses(masked, MARKED_PARENTHETICAL_GLOSS)
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

          separator = /(\s*,\s*|\s+(?:and|or)\s+)/i
          parts     = captures[:terms].split(separator)
          foreign   = parts.each_slice(2).map(&:first).all? do |term|
            term.match?(MARKED_WORD) || @lexicon.term?(term) || !validator.source_prose_word?(term)
          end
          next match unless foreign

          terms = parts.map.with_index do |part, index|
            index.even? ? protect_content(part) : part
          end.join
          gloss = protect_content("(#{register_unit(captures[:gloss])})")
          "#{terms}#{captures[:spacing]}#{gloss}"
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

      def mask_parenthetical_foreign_equivalents(source)
        source.gsub(PARENTHETICAL_FOREIGN_EQUIVALENT) do |match|
          captures = Regexp.last_match
          next match unless validator.protected_inline_fragment?(captures[:equivalent])

          protect_content(
            "#{register_unit(captures[:term])}#{captures[:spacing]}(#{captures[:equivalent]})"
          )
        end
      end

      def mask_parenthetical_clauses(source)
        source.gsub(PARENTHETICAL_CONTENT) do |match|
          captures = Regexp.last_match
          content = captures[:content]
          next protect_content(match) if validator.protected_inline_fragment?(content)

          words = CGI.unescapeHTML(content).scan(/[A-Za-z][A-Za-z'’-]*/)
          quantified_term = /\b#{QUANTIFIER}\s+[A-Za-z-]+\s+[A-Za-z'’-]+\s*\z/
          next match if words.empty? || (words.one? && words.first.length == 1)
          next match if content.match?(/[\[\]]/) || captures.pre_match.match?(quantified_term)
          next match unless translatable?(content)

          protect_content("(#{register_unit(content)})")
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
          if pattern == MARKED_PHRASE_GLOSS || pattern == ASCII_PHRASE_PARENTHETICAL_GLOSS
            words = CGI.unescapeHTML(term).scan(/[A-Za-z][A-Za-z'’-]*/)
            next match if words.any? { |word| english_function_word?(word) }
          end

          protect_content("#{term}#{spacing}#{opening}#{register_unit(gloss)}#{closing}#{suffix}")
        end
      end
    end
  end
end
