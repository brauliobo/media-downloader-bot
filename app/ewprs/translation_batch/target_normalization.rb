require 'cgi'

module Ewprs
  class TranslationBatch
    # What the model leaves behind in a translation, put right per target language: full-width
    # punctuation, stray scripts, English words it copied across and the French it gets wrong.
    module TargetNormalization
      include TranslationMarkup

      # Applied in this order, as the later ones read what the earlier ones wrote.
      FRENCH_LITERALS = [
        ['整个系统违背了人类心理，因此产量永远不会增加。', 'L’ensemble du système va à l’encontre de la psychologie humaine, de sorte que la ' \
          'production n’augmentera jamais.'],
        ['他们', ' ils'],
        ['自我', 'ego'],
        ['？', '?'],
        ['，', ','],
        ['aplatи', 'aplati'],
        ['Mrtyuх', 'Mrtyuh'],
        ['further crudification supplémentaire', 'grossification supplémentaire'],
        ['further blending', 'mélange supplémentaire'],
        ['further grossification', 'grossification supplémentaire'],
        ['further crudification', 'grossification supplémentaire'],
        ['une further grossissement', 'un grossissement supplémentaire'],
        ['further spinning', 'filage supplémentaire'],
        ['further physical clash', 'conflit physique supplémentaire'],
        ['une further distortion', 'une nouvelle déformation'],
        ['une further metamorphosis', 'une nouvelle métamorphose'],
        ['une further dégénérescence', 'une dégénérescence supplémentaire'],
        ['une further disintegration', 'une désintégration accrue'],
        ['a été further subdivisée', 'a été subdivisée davantage'],
        ['est further subdivisé', 'est encore subdivisé'],
        ['further développée', 'développée davantage'],
        ['une further splitting', 'une division supplémentaire'],
        ['The Supreme Entity est un flux continu de cognition', 'L’Entité suprême est un flux continu de cognition'],
        ['Videha liina are caused by ones bhavapratyaya', 'Les Videha liina sont causés par le bhavapratyaya propre à chacun'],
        ['all the three types of vrttis', 'les trois types de vrttis'],
        ['Sa&#x301;hitya means all those', 'Sa&#x301;hitya désigne toutes ces'],
        ['Ma&#x301;gadhii language of that time', 'la langue Ma&#x301;gadhii de l’époque'],
        ['Vargiiya Ba and Antahstha Va to Osadhipati', 'Ba Vargiiya et Va Antahstha jusqu’à Osadhipati'],
      ].freeze
      FRENCH_AGREEMENTS = [
        [/\bla salut\b/i, 'le salut'], [/\bune salut\b/i, 'un salut'], [/\bune telle salut\b/i, 'un tel salut'],
        [/\bsa propre salut\b/i, 'son propre salut'], [/\bsalut spirituelle\b/i, 'salut spirituel'],
        [/\bsalut permanente\b/i, 'salut permanent'],
      ].freeze

      private

      def normalize_target_language(value, strip_glue: true)
        value = value.tr('，？！：；．', ',?!:;.')
        value = strip_cjk_leftover_glue(value) if strip_glue && TranslationValidator::CJK_TARGET.key?(target)
        value = correct_german(value) if target == 'de'
        target == 'fr' ? correct_french(value) : value
      end

      def correct_german(value)
        value.gsub(/\b[Ii]lliterate\b/) { |word| word.start_with?('I') ? 'Ungebildete' : 'ungebildete' }
      end

      def correct_french(value)
        value = FRENCH_LITERALS.reduce(value) { |text, (from, to)| text.gsub(from, to) }
      value = replace_unquoted(
        value, 'has been formed by adding the Farsi suffix',
        'a été formé par l’ajout du suffixe persan'
      )
      value = replace_unquoted(value, 'Human Life and Its', 'La vie humaine et son')
      value = replace_unquoted(value, /\bNucleus\b/, 'noyau')
      value = replace_unquoted(value, /\bsalvation\b/i) do |word, pre|
        pre.to_s.split(/[.!?]/).last.to_s.match?(/\bterme anglais\b/i) ? word : 'salut'
      end
      value = FRENCH_AGREEMENTS.reduce(value) { |text, (pattern, replacement)| text.gsub(pattern, replacement) }
      value = value.gsub(/\b([Ll])orsque\s+([uU]n(?:e)?|ils)\b/) do
        prefix = Regexp.last_match(1) == 'L' ? 'Lorsqu’' : 'lorsqu’'
        "#{prefix}#{Regexp.last_match(2).downcase}"
      end.gsub(/\b([Qq])ue\s+ils\b/) do
        Regexp.last_match(1) == 'Q' ? 'Qu’ils' : 'qu’ils'
      end
      value.gsub(/\b([Cc])e\s+[uU]nivers\b/) do
        Regexp.last_match(1) == 'C' ? 'Cet univers' : 'cet univers'
      end
      end

      def strip_introduced_foreign_scripts(source, translated)
        return translated unless TranslationValidator::LATIN_TARGETS.key?(target)

        allowed = source.to_s.scan(TranslationValidator::NON_LATIN_ARTIFACT).tally
        allowed.default = 0
        translated.to_s.gsub(TranslationValidator::NON_LATIN_ARTIFACT) do |character|
          next character if (allowed[character] -= 1) >= 0

          ''
        end
      end

      def replace_unquoted(value, pattern, replacement = nil, &block)
        held = []
        hold = ->(span) do
          held << span
          "__Q#{held.size}__"
        end
        masked = value.to_s.gsub(/&ldquo;.*?&rdquo;|&lsquo;.*?&rsquo;|“.*?”|‘.*?’|«\s*.*?\s*»/mi, &hold)
        masked = if block
          masked.gsub(pattern) { |word| block.call(word, $`) }
        else
          masked.gsub(pattern, replacement)
        end
        held.each_with_index.reverse_each { |span, index| masked.sub!("__Q#{index + 1}__", span) }
        masked
      end

      def strip_cjk_leftover_glue(value)
        return value unless value.match?(TranslationValidator::CJK_SCRIPT)

        held = []
        hold = ->(span) do
          held << span
          "__Q#{held.size}__"
        end
        masked = value.gsub(/&ldquo;.*?&rdquo;|&lsquo;.*?&rsquo;|『.*?』|「.*?」|".*?"/mi, &hold)
        masked = masked.gsub(/&(?:#\d+|#x[\da-f]+|[a-z][\w]*);/i, &hold)
        masked = masked.gsub(Regexp.union(
          TranslationValidator::RETAINED_ENGLISH_IDIOMS.keys +
            TranslationValidator::ENGLISH_DISCOURSE_OPENERS.keys
        ), &hold)
        glue = '(?:the|an|this|that|these|those|in|on|at|from|to|of|for|with|by|and|or|said|regarding|so-called)'
        cjk  = TranslationValidator::CJK_SCRIPT
        coordinator = target == 'zh' ? '和' : 'と'
        masked = masked.gsub(/(?<![\p{Latin}\p{M}#;])#{glue}\s*(?=#{cjk})/iu, '')
          .gsub(/(#{cjk}[[:punct:]]*)\s*#{glue}(?![\p{Latin}\p{M}#&;_])/iu, '\1')
          .gsub(/\b(?:in|on|at|from|to|of|for|with|by)\s+(?=[\p{Latin}\p{M}'’-]+\s*#{cjk})/iu, '')
          .gsub(/(?<=[\p{Latin}\p{M}'’-])\s+said\b,?/iu, '')
          .gsub(/\bregarding\b,?/iu, '')
          .gsub(/(?<![A-Za-z])([A-Za-z][A-Za-z\p{M}'’-]{0,24})\s+and\s+(?=[A-Za-z])/u, "\\1#{coordinator}")
          .sub(/\A[ \t]+/, '')
        held.each_with_index.reverse_each { |span, index| masked.sub!("__Q#{index + 1}__", span) }
        masked
      end

      def strip_echoed_protected_ascii(unit, output)
        return output unless TranslationValidator::CJK_TARGET.key?(target)

        held = []
        hold = ->(span) do
          held << span
          "__Q#{held.size}__"
        end
        projected = output.to_s.gsub(/&ldquo;.*?&rdquo;|&lsquo;.*?&rsquo;|『.*?』|「.*?」|".*?"/mi, &hold)
        unit.tokens.flat_map { |marker, value| [marker, value] }.uniq.sort_by { |span| -span.size }.each do |span|
          next if span.empty?

          projected.gsub!(span, &hold)
        end
        unit.tokens.each do |marker, value|
          present = output.to_s.include?(marker) || output.to_s.include?(value)
          next unless present

          unicode = CGI.unescapeHTML(value.gsub(MARKUP, '').gsub(UNIT_MARKER, ''))
          next unless unicode.match?(/\p{M}/)

          ascii = ascii_fold_protected(value)
          collisions = unit.tokens.except(marker).values.flat_map { |other| [other, ascii_fold_protected(other)] }
          echoes = [ascii, unicode, unicode.unicode_normalize(:nfc), unicode.unicode_normalize(:nfd)]
          echoes.uniq.each do |echo|
            next if echo.size < 4 || echo == value || echo.include?('&')
            next if collisions.any? { |other| other.include?(echo) }
            next if value.match?(exact_phrase_pattern(echo))

            projected.gsub!(exact_phrase_pattern(echo), '')
          end
        end
        held.each_with_index.reverse_each { |span, index| projected.sub!("__Q#{index + 1}__", span) }
        projected
      end

      def ascii_fold_protected(value)
        CGI.unescapeHTML(value.gsub(MARKUP, '').gsub(UNIT_MARKER, ''))
           .unicode_normalize(:nfd).gsub(/\p{M}/, '').gsub(/[^A-Za-z]/, '')
      end

      def exact_phrase_pattern(value)
        boundary = TranslationValidator::CJK_TARGET.key?(target) ? '\p{Latin}\p{M}' : '\p{L}\p{M}'
        opening = value.match?(/\A[\p{L}\p{M}]/u) ? "(?<![#{boundary}])" : ''
        closing = value.match?(/[\p{L}\p{M}]\z/u) ? "(?![#{boundary}])" : ''
        Regexp.new("#{opening}#{Regexp.escape(value)}#{closing}", Regexp::IGNORECASE)
      end
    end
  end
end
