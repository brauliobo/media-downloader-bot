module Ewprs
  class TranslationValidator
    # The translation must be in the target language: no foreign scripts, no English left behind in a CJK target.
    module TargetLanguage
      include Lexicon

      private

      def validate_introduced_scripts!(source, translated)
        return unless LATIN_TARGETS.key?(target_language)

        source_counts = source.to_s.scan(NON_LATIN_ARTIFACT).tally
        source_counts.default = 0
        introduced = translated.to_s.scan(NON_LATIN_ARTIFACT).find do |character|
          source_counts[character] -= 1
          source_counts[character].negative?
        end
        return unless introduced

        raise Error.new(:script, "translation introduced foreign-script character: #{introduced}")
      end

      def validate_target_language!(source, translated)
        translated = mask_pedagogical_articles(source, translated)
        visible = visible_text(translated)
        unquoted = strip_quoted_spans(visible)
        invalid = target_invalid_phrases.find { |pattern, _message| visible.match?(pattern) }
        invalid ||= english_discourse_openers.find { |pattern, _message| unquoted.match?(pattern) }
        if invalid
          pattern, message = invalid
          phrase = (visible[pattern] || unquoted[pattern])
          raise Error.new(:target_language, "#{message}: #{phrase}")
        end

        compound = retained_cjk_hyphenated_compound(unquoted)
        if compound
          raise Error.new(:target_language, "retained English compound: #{compound}")
        end

        determiner = retained_cjk_determiner(unquoted, source)
        if determiner
          raise Error.new(:target_language, "retained English determiner: #{determiner}")
        end

        coordinator = retained_cjk_coordinator(unquoted.gsub(/\([^()]*\)/, ' '))
        return unless coordinator

        raise Error.new(:target_language, "retained English coordinator: #{coordinator}")
      end

      def target_invalid_phrases
        phrases = TARGET_INVALID_PHRASES.fetch(target_language, {})
        return phrases if target_language == 'en' || source_language == target_language

        RETAINED_ENGLISH_IDIOMS.merge(phrases)
      end

      def english_discourse_openers
        return {} if target_language == 'en' || source_language == target_language

        ENGLISH_DISCOURSE_OPENERS
      end

      PEDAGOGICAL_ARTICLE = /(?:#{MARKER}|<I>)\s*(a|an|the)\s*(?:#{MARKER}|<\/I>)/i

      def mask_pedagogical_articles(source, translated)
        allowed = source.to_s.scan(PEDAGOGICAL_ARTICLE).flatten.map(&:downcase)
        return translated if allowed.empty?

        translated.to_s.gsub(PEDAGOGICAL_ARTICLE) do |match|
          article = Regexp.last_match(1)
          allowed.include?(article.downcase) ? match.sub(/#{Regexp.escape(article)}/i, ' ') : match
        end
      end

      def retained_cjk_determiner(text, source)
        return unless CJK_TARGET.key?(target_language)
        return unless text.match?(CJK_SCRIPT)

        pedagogical = source.to_s.scan(PEDAGOGICAL_ARTICLE).flatten.map(&:downcase).uniq
        unless pedagogical.empty?
          text = text.gsub(/\b(?:#{pedagogical.map { |article| Regexp.escape(article) }.join('|')})\b/i, ' ')
        end
        text[CJK_RETAINED_DETERMINER]
      end

      def retained_cjk_coordinator(text)
        return unless CJK_TARGET.key?(target_language)
        return unless text.match?(CJK_SCRIPT)

        text[CJK_RETAINED_COORDINATOR]
      end

      def retained_cjk_hyphenated_compound(text)
        return unless CJK_TARGET.key?(target_language)

        dictionary = SOURCE_WORDS.fetch(source_language, {})
        anchors = SOURCE_PROSE_ANCHORS.fetch(source_language, {})
        text.to_s.scan(ENGLISH_HYPHENATED_COMPOUND).find do |word|
          key = word.downcase
          next false if ALLOWED_ENGLISH_HYPHENS.key?(key)

          english_hyphenated_compound?(key, dictionary, anchors)
        end
      end

      def english_hyphenated_compound?(word, dictionary, anchors)
        parts = word.split('-')
        return false if parts.size < 2
        return true if ENGLISH_HYPHEN_HEADS.key?(parts.first) && english_hyphen_part?(parts.last, dictionary, anchors)

        parts.all? { |part| english_hyphen_part?(part, dictionary, anchors) }
      end

      def english_hyphen_part?(part, dictionary, anchors)
        dictionary.key?(part) || anchors.key?(part) || (part.size >= 5 && part.match?(ENGLISH_HYPHEN_TAIL))
      end

      def strip_quoted_spans(text)
        text.to_s
            .gsub(/&ldquo;.*?&rdquo;/mi, ' ')
            .gsub(/&lsquo;.*?&rsquo;/mi, ' ')
            .gsub(/“.*?”/m, ' ')
            .gsub(/「.*?」/m, ' ')
            .gsub(/『.*?』/m, ' ')
            .gsub(/".*?"/m, ' ')
      end
    end
  end
end
