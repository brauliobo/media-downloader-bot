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

    include Structure
    include ProtectedValues
    include TargetLanguage
    include Progress

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
  end
end
