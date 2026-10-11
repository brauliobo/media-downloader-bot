module Ewprs
  class TranslationValidator
    # The translation must have gone further than copying the source: words kept, sentences repeated, prose left as it was.
    module Progress
      include Lexicon

      private

      def validate_translation_progress!(source, translated, protected_context: false)
        source_words = normalized_words(source)
        target_words = normalized_words(translated)
        return if source_words.empty?
        if target_words.empty?
          omittable = OMITTABLE_SOURCE_WORDS.fetch(target_language, {})
          return if protected_context && source_words.all? { |word| omittable.key?(word) }
          return if protected_source_fragment?(source) || formula_or_reference?(source)

          excerpt = visible_text(source)[0, 80]
          raise Error.new(:untranslated, "translation omitted source prose: #{excerpt}")
        end

        if source_words == target_words && untranslated_prose?(source, source_words) &&
           !shared_target_phrase?(source_words)
          excerpt = visible_text(source)[0, 80]
          raise Error.new(:untranslated, "translation left source prose unchanged: #{excerpt}")
        end

        source_words = normalized_words(visible_text(source).gsub(FORMULA_EXPRESSION, ' '))
        target_words = normalized_words(visible_text(translated).gsub(FORMULA_EXPRESSION, ' '))
        return if source_words.empty? || target_words.empty?

        max_span = [source_words.size, 12].min
        return if max_span < 5

        retained = max_span.downto(5).any? do |span|
          required_common = [[4, (span * 0.6).ceil].max, 8].min
          retained_source_span?(source_words, target_words, span, required_common)
        end
        return unless retained

        raise Error.new(:untranslated, 'translation retained a long source-language span')
      end

      def validate_retained_source_words!(source, translated)
        forbidden = RETAINED_SOURCE_WORDS.fetch(target_language, {})
        return if forbidden.empty?

        source_counts = retained_word_candidates(source).tally
        retained = retained_word_candidates(translated).find do |word|
          next false unless forbidden.key?(word) && source_counts.fetch(word, 0).positive?
          next false if word == 'salvation' && visible_text(translated).match?(/\bterme anglais\b.*\bsalvation\b/i)

          source_counts[word] -= 1
          true
        end
        return unless retained

        raise Error.new(:untranslated, "translation retained source-language word: #{retained}")
      end

      def validate_sentence_duplicates!(source, translated)
        source_profile = duplicate_profile(source)
        added = duplicate_profile(translated).each_with_index.any? do |count, index|
          count > source_profile.fetch(index, 1)
        end
        raise Error.new(:duplicate_sentence, 'translation duplicated a source sentence') if added
      end

      def duplicate_profile(value)
        sentences(value).tally.filter_map do |sentence, count|
          count if count > 1 && sentence.split.size >= 4
        end.sort.reverse
      end

      def sentences(value)
        visible_text(value).split(/(?<=[.!?])[”\]]*\s+/).map do |sentence|
          normalized_words(sentence).join(' ')
        end.reject(&:empty?)
      end

      def retained_source_span?(source, target, span, required_common)
        target_spans = target.each_cons(span).to_h { |words| [words, true] }
        source.each_cons(span).any? do |words|
          target_spans.key?(words) && source_words(words) >= required_common
        end
      end

      def untranslated_prose?(source, words)
        return false if words.size < 2 || formula_or_reference?(source)
        return false if protected_source_fragment?(source)

        english = source_words(words)
        return true if english >= 2 || source_suffix_words(words) >= 2

        english.positive? && source_prose_anchor?(words, source: source)
      end

      def formula_or_reference?(source)
        text = visible_text(source)
        text.match?(/[+=→]/) ||
          text.match?(/\A\(.+\b[IVX]+,\s*\d+\)\z/i) ||
          text.match?(/\b[A-Z]\.\s*(?:[a-z]+\.)?\z/)
      end

      def source_words(words)
        dictionary = SOURCE_WORDS.fetch(source_language, {})
        words.count { |word| dictionary.key?(word) }
      end

      def source_suffix_words(words)
        suffixes = SOURCE_SUFFIXES[source_language]
        suffixes ? words.count { |word| word.match?(suffixes) } : 0
      end

      def shared_target_phrase?(words)
        shared = TARGET_SHARED_WORDS.fetch(target_language, {})
        words.all? { |word| shared.key?(word) } ||
          TARGET_SHARED_PHRASES.fetch(target_language, []).include?(words)
      end

      def source_prose_anchor?(words, source: nil)
        anchors = SOURCE_PROSE_ANCHORS.fetch(source_language, {}).merge(
          RETAINED_SOURCE_WORDS.fetch(target_language, {}),
          SOURCE_PROSE_ANCHORS.fetch(target_language, {}),
          PROTECTED_CONNECTORS.fetch(target_language, {})
        )
        return true if words.any? { |word| anchors.key?(word) }

        connectors = SOURCE_PROSE_CONNECTORS.fetch(source_language, {})
        source_words(words) >= 2 && words.any? { |word| connectors.key?(word) }
      end

      def marked_word_count(value)
        text = visible_text(value).unicode_normalize(:nfd)
        text.scan(WORD).count { |word| word.match?(/\p{M}/u) }
      end

      def normalized_words(value)
        visible_text(value).unicode_normalize(:nfc).downcase.scan(WORD)
      end

      def retained_word_candidates(value)
        components = RETAINED_HYPHEN_COMPONENTS.fetch(target_language, {})
        attached   = RETAINED_ATTACHED_COMPONENTS.fetch(target_language, {})
        normalized_words(value).flat_map do |word|
          suffixes = attached.keys.select do |suffix|
            prefix = word.delete_suffix(suffix)
            prefix != word && prefix.unicode_normalize(:nfd).match?(/\p{M}/u)
          end
          [word, *word.split('-').select { |component| components.key?(component) }, *suffixes]
        end
      end
    end
  end
end
