module SpokenText
  # Digits are left to the TTS engine, and engines only normalize a few languages: "7.000" comes out as
  # "7 zero" and "414ª" as "414-lha". Written out in the language it is spoken in, a number reads right.
  module Numbers
    # English and Chinese are normalized by the engine itself, which knows how a year is read.
    NATIVE     = %w[en zh].freeze
    LOCALES    = { 'pt' => :'pt-BR' }.freeze
    # The gem spells ordinals correctly only in Portuguese; elsewhere it falls back to the cardinal.
    ORDINALS   = %w[pt].freeze
    FEMININE   = 'ª'.freeze
    GROUP_GAPS = "   ".freeze
    MAX_DIGITS = 15

    # A grouped integer ("7.000", "1.234.567") or a plain one, an optional decimal part and an ordinal
    # mark. A number glued to a letter, a date, a time or a version is not a quantity, so it is left alone.
    NUMBER = /
      (?<![\p{L}\p{N}\/:.,])
      (?<int>\d{1,3}(?:[.#{GROUP_GAPS}]\d{3})+|\d+)
      (?:[,.](?<dec>\d+))?
      (?<ordinal>\.?[ºª])?
      (?![\p{L}\p{N}]|[\/:.,]\d)
    /x

    class << self
      def call(text, lang)
        locale = locale_for(lang)
        return text.to_s unless locale

        text.to_s.gsub(NUMBER) { spell(Regexp.last_match, lang_code(lang), locale) || Regexp.last_match[0] }
      end

      private

      def lang_code(lang) = lang.to_s.downcase[/\A[a-z]+/]

      def locale_for(lang)
        code = lang_code(lang)
        return if code.nil? || NATIVE.include?(code)

        locale = LOCALES.fetch(code, code.to_sym)
        locale if I18n.exists?(:numbers, locale)
      end

      def spell(match, code, locale)
        int = match[:int].delete(".#{GROUP_GAPS}")
        return if int.length > MAX_DIGITS || (int.length > 1 && int.start_with?('0'))

        I18n.with_locale(locale) do
          if match[:ordinal]
            ordinal(int, match[:dec], match[:ordinal], code)
          else
            words(match[:dec] ? Float("#{int}.#{match[:dec]}") : int.to_i)
          end
        end
      end

      def ordinal(int, dec, mark, code)
        return if dec || ORDINALS.exclude?(code)

        spelled = words(int.to_i, ordinal: true)
        mark.end_with?(FEMININE) ? spelled.gsub(/o\b/, 'a') : spelled
      end

      # The commas the gem puts between groups would be read as pauses.
      def words(number, **options) = number.to_words(**options).delete(',')
    end
  end
end
