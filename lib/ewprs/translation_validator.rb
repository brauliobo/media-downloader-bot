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

    MARKUP = /<!--.*?-->|<[^>]+>/m
    MARKER = /__P\d{4}__|⟦[UP][^⟧]*⟧/
    ESCAPED_CHARACTER_REFERENCE = /&amp;(?=(?:#\d+|#x[\da-f]+|[a-z][\w]+))/i
    WORD = /\p{L}[\p{L}\p{M}]*(?:[-'’]\p{L}[\p{L}\p{M}]*)*/u
    FORMULA_EXPRESSION = %r{
      (?<![\p{L}\p{M}])[\p{L}\p{M}]+(?:\s*[+=→]\s*[\p{L}\p{M}]+)+(?![\p{L}\p{M}])
    }ux
    SOURCE_WORDS = {
      'en' => %w[
        a about above after again all also although an and another any are as at be because been before being
        below between body both but by call called came can could cosmic did do does down during each english entity even
        every few first for force fountain from further get go got had has have he her here him his how human i if in into
        is it its just know last life like made make many may me mean means might mind more most much must my new no nor
        not now of off old on once one only or other our out over own people power same said say second see she
        sentence should so society some soul source spiritual spraying still such supreme take than that the their them then there these title
        they thing this those though three through time to too two under up us very was way we well were what when
        water where which while who whom why will with world would you your
      ].to_h { |word| [word, true] }.freeze
    }.freeze
    SOURCE_SUFFIXES = {
      'en' => /(?:able|hood|ible|ise|ised|ises|ising|ity|ive|less|ly|ment|ness|ous|ship|sion|tion|ward|wise|ize|ized|izes|izing)\z/
    }.freeze
    RETAINED_SOURCE_WORDS = {
      'fr' => %w[further nucleus salvation stamina].to_h { |word| [word, true] }.freeze
    }.freeze
    TARGET_SHARED_WORDS = {
      'es' => %w[no oh].to_h { |word| [word, true] }.freeze
    }.freeze
    TARGET_INVALID_PHRASES = {
      'fr' => {
        /\blorsque (?:un|une)\b/i => 'invalid French elision',
        /\bce univers\b/i          => 'invalid French demonstrative',
      }.freeze
    }.freeze
    DELIMITER_PAIRS = {'(' => ')', '[' => ']', '{' => '}'}.freeze
    DELIMITER = /[()\[\]{}]/
    EDITORIAL_BRACKET = /\[\[?|\]\]?/
    DOUBLE_SMART_QUOTE = /&(?:l|r)dquo;|[“”«»]/i
    EMPTY_SMART_QUOTES = /(?:&ldquo;\s*&rdquo;|&lsquo;\s*&rsquo;|“\s*”|‘\s*’|«\s*»)/i
    REVERSED_SMART_QUOTES = /(?:&rdquo;\s*&ldquo;|&rsquo;\s*&lsquo;|”\s*“|’\s*‘|»\s*«)/i
    NON_LATIN_ARTIFACT = /[\p{Han}\p{Cyrillic}\uFF00-\uFFEF]/u
    LATIN_TARGETS = %w[en es fr pt].to_h { |language| [language, true] }.freeze

    attr_reader :source_language, :target_language

    def initialize(source_language:, target_language:)
      @source_language = source_language.to_s.downcase
      @target_language = target_language.to_s.downcase
    end

    def valid?(source:, translated:, protected_values: [])
      validate!(source: source, translated: translated, protected_values: protected_values)
      true
    rescue Error
      false
    end

    def validate!(source:, translated:, protected_values: [])
      validate_line_breaks!(source, translated)
      validate_delimiters!(source, translated)
      validate_escaped_character_references!(source, translated)
      validate_smart_quotes!(source, translated)
      validate_introduced_scripts!(source, translated)
      validate_protected!(source: source, translated: translated, protected_values: protected_values)
      unless source_language == target_language
        counts = protected_value_counts(source, protected_values)
        unprotected_source = without_protected_values(source, counts)
        unprotected_translation = without_protected_values(translated, counts)
        validate_translation_progress!(
          unprotected_source, unprotected_translation
        )
        validate_retained_source_words!(unprotected_source, unprotected_translation)
        validate_target_language!(unprotected_translation)
      end
      validate_sentence_duplicates!(source, translated)
      true
    end

    def validate_protected!(source:, translated:, protected_values:)
      expected_values = protected_value_counts(source, protected_values)
      changed = expected_values.find do |value, expected_count|
        next false if value.match?(MARKER) || !visible_text(value).match?(/\p{L}/u)

        translated.scan(protected_value_pattern(value)).size < expected_count
      end
      return true unless changed

      excerpt = visible_text(changed.first)[0, 80]
      raise Error.new(:protected_values, "translation changed protected source text: #{excerpt}")
    end

    def protected_source_fragment?(source)
      words = normalized_words(source)
      return false if words.size < 4

      source_word_ratio = source_words(words).fdiv(words.size)
      return false if source_word_ratio > 0.2

      marked = marked_word_count(source)
      marked >= 2 && marked.fdiv(words.size) >= 0.25
    end

    def protected_inline_fragment?(source)
      words = normalized_words(source)
      return true if words.one? && visible_text(source).match?(/\A\p{L}\p{M}*[,;]?\z/u)

      words.size >= 2 && source_words(words).zero? && marked_word_count(source).positive?
    end

    private

    def protected_value_counts(source, protected_values)
      return protected_values if protected_values.respond_to?(:each_pair)

      protected_values.uniq.to_h do |value|
        [value, source.scan(protected_value_pattern(value)).size]
      end
    end

    def without_protected_values(value, counts)
      counts.each_with_object(value.to_s.dup) do |(protected, count), text|
        next if protected.match?(MARKER)

        count.times { text.sub!(protected_value_pattern(protected), ' ') }
      end
    end

    def validate_line_breaks!(source, translated)
      return if line_breaks(source) == line_breaks(translated)

      raise Error.new(:line_breaks, 'translation changed line breaks')
    end

    def validate_delimiters!(source, translated)
      source_text = visible_text(source)
      translated_text = visible_text(translated)
      changed = source_text.scan(DELIMITER) != translated_text.scan(DELIMITER)
      changed ||= source_text.scan(EDITORIAL_BRACKET) != translated_text.scan(EDITORIAL_BRACKET)
      raise Error.new(:delimiters, 'translation changed paired delimiters') if changed
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
      if translated.to_s.scan(REVERSED_SMART_QUOTES).size > source.to_s.scan(REVERSED_SMART_QUOTES).size
        raise Error.new(:quotes, 'translation introduced reversed smart quotes')
      end
      return if translated.to_s.scan(EMPTY_SMART_QUOTES).size <= source.to_s.scan(EMPTY_SMART_QUOTES).size

      raise Error.new(:quotes, 'translation introduced empty smart quotes')
    end

    def balanced_double_quotes?(value)
      balance = 0
      value.to_s.scan(DOUBLE_SMART_QUOTE).all? do |quote|
        balance += quote.match?(/&ldquo;|[“«]/i) ? 1 : -1
        balance >= 0
      end && balance.zero?
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

    def validate_translation_progress!(source, translated)
      source_words = normalized_words(source)
      target_words = normalized_words(translated)
      return if source_words.empty? || target_words.empty?

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
        required_common = [8, (span * 0.6).ceil].min
        retained_source_span?(source_words, target_words, span, required_common)
      end
      return unless retained

      raise Error.new(:untranslated, 'translation retained a long source-language span')
    end

    def validate_retained_source_words!(source, translated)
      forbidden = RETAINED_SOURCE_WORDS.fetch(target_language, {})
      return if forbidden.empty?

      source_counts = normalized_words(source).tally
      retained = normalized_words(translated).find do |word|
        next false unless forbidden.key?(word) && source_counts[word].positive?
        next false if word == 'salvation' && visible_text(translated).match?(/\bterme anglais\b.*\bsalvation\b/i)

        source_counts[word] -= 1
        true
      end
      return unless retained

      raise Error.new(:untranslated, "translation retained source-language word: #{retained}")
    end

    def validate_target_language!(translated)
      invalid = TARGET_INVALID_PHRASES.fetch(target_language, {}).find do |pattern, _message|
        visible_text(translated).match?(pattern)
      end
      return unless invalid

      pattern, message = invalid
      phrase = visible_text(translated)[pattern]
      raise Error.new(:target_language, "#{message}: #{phrase}")
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

      source_words(words) >= 2 || source_suffix_words(words) >= 2
    end

    def formula_or_reference?(source)
      text = visible_text(source)
      text.match?(/[+=→]/) ||
        text.match?(/\A\(.+\b[IVX]+,\s*\d+\)\z/i) ||
        text.match?(/\b[A-Z]\.\s*(?:[a-z]+\.)?\z/)
    end

    def protected_value_pattern(value)
      prefix = '(?<![\p{L}\p{M}])' if value.match?(/\A[\p{L}\p{M}]/u)
      suffix = '(?![\p{L}\p{M}])' if value.match?(/[\p{L}\p{M}]\z/u)
      Regexp.new("#{prefix}#{Regexp.escape(value)}#{suffix}", Regexp::MULTILINE)
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
      words.all? { |word| shared.key?(word) }
    end

    def marked_word_count(value)
      text = visible_text(value).unicode_normalize(:nfd)
      text.scan(WORD).count { |word| word.match?(/\p{M}/u) }
    end

    def normalized_words(value)
      visible_text(value).unicode_normalize(:nfc).downcase.scan(WORD)
    end

    def visible_text(value)
      CGI.unescapeHTML(value.to_s.gsub(MARKUP, ' ').gsub(MARKER, ' ')).split.join(' ')
    end

    def line_breaks(value)
      value.to_s.scan(/\r\n|\r|\n/)
    end
  end
end
