module Ewprs
  class TranslationValidator
    # Protected values and connectors must come through the translation as they went in.
    module ProtectedValues
      include Lexicon

      def validate_protected!(source:, translated:, protected_values:)
        expected_values = protected_value_counts(source, protected_values)
        changed = expected_values.find do |value, expected_count|
          next false if value.match?(MARKER) || !visible_text(value).match?(/\p{L}/u)

          translated.scan(protected_value_pattern(value, target_text: true)).size < expected_count
        end
        return true unless changed

        excerpt = visible_text(changed.first)[0, 80]
        raise Error.new(:protected_values, "translation changed protected source text: #{excerpt}")
      end

      def protected_source_fragment?(source)
        words = normalized_words(source)
        return false if words.size < 4
        return false if source_prose_anchor?(words, source: source)

        source_word_ratio = source_words(words).fdiv(words.size)
        return false if source_word_ratio > 0.2

        marked = marked_word_count(source)
        marked >= 2 && marked.fdiv(words.size) >= 0.25
      end

      def protected_inline_fragment?(source)
        words = normalized_words(source)
        return false if source_prose_anchor?(words, source: source)

        single_word = visible_text(source).match?(/\A(?:\p{L}\p{M}*)+[,;]?\z/u)
        return true if words.one? && (
          visible_text(source).match?(/\A\p{L}\p{M}*[,;]?\z/u) ||
          (single_word && marked_word_count(source).positive?)
        )

        words.size >= 2 && source_words(words).zero? && marked_word_count(source).positive?
      end

      def source_prose_word?(value)
        words = normalized_words(value)
        dictionary = SOURCE_WORDS.fetch(source_language, {})
        anchors = RETAINED_SOURCE_WORDS.fetch(target_language, {}).merge(
          SOURCE_PROSE_ANCHORS.fetch(target_language, {}),
          PROTECTED_CONNECTORS.fetch(target_language, {})
        )
        words.any? { |word| dictionary.key?(word) || anchors.key?(word) }
      end

      private

      def protected_value_counts(source, protected_values)
        return protected_values if protected_values.respond_to?(:each_pair)

        protected_values.uniq.to_h do |value|
          [value, source.scan(protected_value_pattern(value)).size]
        end
      end

      def without_protected_values(value, counts, target_text: false)
        counts.each_with_object(value.to_s.dup) do |(protected, count), text|
          next if protected.match?(MARKER)

          count.times { text.sub!(protected_value_pattern(protected, target_text: target_text), ' ') }
        end
      end

      def validate_retained_protected_connectors!(source, translated, protected_connectors)
        connectors = PROTECTED_CONNECTORS.fetch(target_language, {})
        return if connectors.empty?

        pattern = /(?<left>#{MARKER})(?<punctuation>[.,;]*)\s+(?<connector>#{Regexp.union(connectors.keys)})\s+(?<right>#{MARKER})/i
        retained = source.to_s.scan(pattern).find do |left, punctuation, connector, right|
          translated.to_s.match?(
            /#{Regexp.escape(left)}#{Regexp.escape(punctuation)}\s+#{Regexp.escape(connector)}\s+#{Regexp.escape(right)}/i
          )
        end
        retained ||= protected_connectors.find do |left, punctuation, connector, right|
          next false unless connectors.key?(connector.downcase)

          pair = /#{Regexp.escape(left)}#{Regexp.escape(punctuation)}\s+#{Regexp.escape(connector)}\s+#{Regexp.escape(right)}/i
          source.to_s.match?(pair) && translated.to_s.match?(pair)
        end
        return unless retained

        raise Error.new(:untranslated, "translation retained source-language word: #{retained[2].downcase}")
      end

      def protected_value_pattern(value, target_text: false)
        leading_letter  = value.match(/\A(\p{L})/u)&.[](1)
        trailing_letter = value.match(/(\p{L})\p{M}*\z/u)&.[](1)
        prefix = "(?<![#{protected_boundary_class(leading_letter, target_text: target_text)}])" if leading_letter
        suffix = "(?![#{protected_boundary_class(trailing_letter, target_text: target_text)}])" if trailing_letter
        Regexp.new("#{prefix}#{Regexp.escape(value)}#{suffix}", Regexp::MULTILINE)
      end

      def protected_boundary_class(letter, target_text:)
        return '\p{Latin}\p{M}' if target_text && !LATIN_TARGETS.key?(target_language) &&
                                        letter.match?(/\p{Latin}/u)

        '\p{L}\p{M}'
      end
    end
  end
end
