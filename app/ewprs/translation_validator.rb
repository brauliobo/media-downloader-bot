require 'cgi'

module Ewprs
  class TranslationValidator
    class Error < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    include Lexicon

    MARKUP = /<!--.*?-->|<[^>]+>/m
    MARKER = /__P\d{4}__|⟦[UP][^⟧]*⟧/
    INTERNAL_TRANSPORT_MARKER = /ZXQEWPRS|(?:&lt;|<\/?)?[A-Za-z]?ewprs-|&lt;span\b[^>]*(?:data-ewprs|data=&quot;ewprs)/i
    ESCAPED_CHARACTER_REFERENCE = /&amp;(?=(?:#\d+|#x[\da-f]+|[a-z][\w]+))/i
    WORD = /\p{L}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*/u
    FORMULA_EXPRESSION = %r{
      (?<![\p{L}\p{M}])[\p{L}\p{M}]+(?:\s*[+=→]\s*[\p{L}\p{M}]+)+(?![\p{L}\p{M}])
    }ux
    DELIMITER_PAIRS = {'(' => ')', '[' => ']', '{' => '}'}.freeze
    DELIMITER = /[()\[\]{}]/
    EDITORIAL_BRACKET = /\[\[?|\]\]?/
    DOUBLE_SMART_QUOTE = /&(?:l|r)dquo;|[“”„«»]/i
    EMPTY_SMART_QUOTES = /(?:&ldquo;\s*&rdquo;|&lsquo;\s*&rsquo;|“\s*”|‘\s*’|«\s*»)/i
    NON_LATIN_ARTIFACT = /[\p{Han}\p{Cyrillic}\uFF00-\uFFEF]/u
    CJK_SCRIPT = /[\p{Han}\p{Hiragana}\p{Katakana}]/
    CJK_RETAINED_DETERMINER = /(?<![A-Za-z\p{M}+=])(?:the|an|this|that|these|those|said|regarding|so-called)(?![A-Za-z\p{M}=])/iu
    CJK_RETAINED_COORDINATOR = /(?<![A-Za-z\p{M}])[A-Za-z]{2,24}\s+and\s+[A-Za-z]/u
    LATIN_TARGETS = %w[de en es fr pt].to_h { |language| [language, true] }.freeze

    attr_reader :source_language, :target_language

    def initialize(source_language:, target_language:)
      @source_language = source_language.to_s.downcase
      @target_language = target_language.to_s.downcase
    end

    def valid?(source:, translated:, protected_values: [], protected_connectors: [])
      validate!(
        source: source, translated: translated, protected_values: protected_values,
        protected_connectors: protected_connectors
      )
      true
    rescue Error
      false
    end

    def validate!(source:, translated:, protected_values: [], protected_connectors: [])
      validate_line_breaks!(source, translated)
      validate_delimiters!(source, translated)
      validate_escaped_character_references!(source, translated)
      validate_smart_quotes!(source, translated)
      validate_internal_transport_markers!(source, translated)
      validate_introduced_scripts!(source, translated)
      validate_protected!(source: source, translated: translated, protected_values: protected_values)
      unless source_language == target_language
        validate_retained_protected_connectors!(source, translated, protected_connectors)
        counts = protected_value_counts(source, protected_values)
        unprotected_source      = without_protected_values(source, counts)
        unprotected_translation = without_protected_values(translated, counts, target_text: true)
        validate_translation_progress!(
          unprotected_source, unprotected_translation,
          protected_context: counts.any? || source.to_s.match?(MARKER)
        )
        validate_retained_source_words!(unprotected_source, unprotected_translation)
        validate_target_language!(source, unprotected_translation)
      end
      validate_sentence_duplicates!(source, translated)
      true
    end

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

    def validate_line_breaks!(source, translated)
      return if line_breaks(source) == line_breaks(translated)

      raise Error.new(:line_breaks, 'translation changed line breaks')
    end

    def validate_delimiters!(source, translated)
      source_text = visible_text(source)
      translated_text = visible_text(translated)
      source_profile = balanced_delimiter_profile(source_text)
      translated_profile = balanced_delimiter_profile(translated_text)
      changed = if CJK_TARGET.key?(target_language) && source_profile
        source_profile != translated_profile
      else
        source_text.scan(DELIMITER) != translated_text.scan(DELIMITER)
      end
      changed ||= source_text.scan(EDITORIAL_BRACKET) != translated_text.scan(EDITORIAL_BRACKET)
      raise Error.new(:delimiters, 'translation changed paired delimiters') if changed
    end

    def balanced_delimiter_profile(value)
      openings = DELIMITER_PAIRS.keys.to_h { |opening| [opening, true] }
      closing_to_opening = DELIMITER_PAIRS.invert
      roots = []
      stack = []
      value.scan(DELIMITER).each do |delimiter|
        if openings.key?(delimiter)
          stack << [delimiter, []]
          next
        end

        opening = closing_to_opening.fetch(delimiter)
        return unless stack.last&.first == opening

        node_opening, children = stack.pop
        signature = "#{node_opening}#{children.join}#{delimiter}"
        stack.empty? ? roots << signature : stack.last.last << signature
      end
      return unless stack.empty?

      roots.sort
    end

    def validate_escaped_character_references!(source, translated)
      source_count     = source.to_s.scan(ESCAPED_CHARACTER_REFERENCE).size
      translated_count = translated.to_s.scan(ESCAPED_CHARACTER_REFERENCE).size
      return if translated_count <= source_count

      raise Error.new(:entities, 'translation introduced an escaped HTML character reference')
    end

    def validate_smart_quotes!(source, translated)
      if balanced_double_quotes?(source) && !balanced_double_quotes?(translated)
        raise Error.new(:quotes, 'translation reversed smart quotes')
      end
      return if translated.to_s.scan(EMPTY_SMART_QUOTES).size <= source.to_s.scan(EMPTY_SMART_QUOTES).size

      raise Error.new(:quotes, 'translation introduced empty smart quotes')
    end

    def balanced_double_quotes?(value)
      openings = []
      value.to_s.scan(DOUBLE_SMART_QUOTE).all? do |quote|
        if quote == '“' && openings.last == :german
          openings.pop
        elsif quote.match?(/&ldquo;|[“«]/i)
          openings << :standard
        elsif quote == '„'
          openings << :german
        else
          openings.pop || false
        end
      end && openings.empty?
    end

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

    def validate_internal_transport_markers!(source, translated)
      return if translated.to_s.scan(INTERNAL_TRANSPORT_MARKER).size <=
                source.to_s.scan(INTERNAL_TRANSPORT_MARKER).size

      raise Error.new(:markers, 'translation leaked an internal transport marker')
    end

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

    def visible_text(value)
      CGI.unescapeHTML(value.to_s.gsub(MARKUP, ' ').gsub(MARKER, ' ')).split.join(' ')
    end

    def line_breaks(value)
      value.to_s.scan(/\r\n|\r|\n/)
    end
  end
end
