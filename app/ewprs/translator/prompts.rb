module Ewprs
  class Translator
    # What the model is told: the instructions, the hints for words it tends to leave in English, and the repair requests.
    module Prompts
      QUOTED_PROSE_INSTRUCTION = 'Translate prose inside quotation marks too; quotation marks do not denote protected text.'

      DO_NOT_COPY_ENGLISH = 'Translate that meaning; do not copy English words.'

      SOURCE_TERM_HINTS = {
        'all of North Bengal'    => 'The phrase "all of North Bengal" means every part of that geographic region. ' \
                                    'Do not copy this explanation.',
        'all of South East Asia' => "The phrase \"all of South East Asia\" means the entire Southeast Asian region. #{DO_NOT_COPY_ENGLISH}",
        'anchoring'              => "The English word \"anchoring\" means establishing firmly. #{DO_NOT_COPY_ENGLISH}",
        'cause your downfall'    => "The English phrase \"cause your downfall\" means to bring ruin on someone. #{DO_NOT_COPY_ENGLISH}",
        'definition'             => "The English word \"definition\" means an explanation of what a term means. #{DO_NOT_COPY_ENGLISH}",
        'descended'              => "The English adjective \"descended\" means derived from an earlier language. #{DO_NOT_COPY_ENGLISH}",
        'each of these five'     => "The English phrase \"each of these five\" means every one among those five. #{DO_NOT_COPY_ENGLISH}",
        'edition'                => 'In bibliographic prose, translate "Edition" as the target-language word for a ' \
                                    'publication edition.',
        'extro-internal'         => "The coined adjective \"extro-internal\" describes motion from outside toward inside. #{DO_NOT_COPY_ENGLISH}",
        'intro-external'         => "The coined adjective \"intro-external\" describes motion from inside toward outside. #{DO_NOT_COPY_ENGLISH}",
        'feeder'                 => "The English noun \"feeder\" means someone who nourishes or supplies. #{DO_NOT_COPY_ENGLISH}",
        'illiterate'             => "The English adjective \"illiterate\" means lacking literacy. #{DO_NOT_COPY_ENGLISH}",
        'illustrative'           => "The English adjective \"illustrative\" means given to illustrate. #{DO_NOT_COPY_ENGLISH}",
        'inculcating'            => "The English verb \"inculcating\" means instilling firmly. #{DO_NOT_COPY_ENGLISH}",
        'inject'                 => "The English verb \"inject\" means to put a quality into a person or group. #{DO_NOT_COPY_ENGLISH}",
        'linseed'                => "The English noun \"linseed\" means the seed of the flax plant. #{DO_NOT_COPY_ENGLISH}",
        'literally'              => "The English adverb \"literally\" means in a non-figurative or exact sense. #{DO_NOT_COPY_ENGLISH}",
        'respectively'           => "The English adverb \"respectively\" means each in the order already given. #{DO_NOT_COPY_ENGLISH}",
        'according to'           => "The English preposition means as stated by that source. #{DO_NOT_COPY_ENGLISH}",
        'all-pervasive'          => "The English adjective means present everywhere. #{DO_NOT_COPY_ENGLISH}",
        'beginning of book'      => "This UI label means the start of the book. #{DO_NOT_COPY_ENGLISH}",
        'however'                => "The English adverb means in contrast or nevertheless. #{DO_NOT_COPY_ENGLISH}",
        'in the same way'        => "The English idiom means likewise or analogously. #{DO_NOT_COPY_ENGLISH}",
        'likewise'               => "The English adverb means in the same manner. #{DO_NOT_COPY_ENGLISH}",
        'next chapter'           => "This UI label means the following chapter. #{DO_NOT_COPY_ENGLISH}",
        'online additional information' =>
          "This UI label means extra information available on the website. #{DO_NOT_COPY_ENGLISH}",
        'previous chapter'       => "This UI label means the preceding chapter. #{DO_NOT_COPY_ENGLISH}",
        'self-illuminating'      => "The English adjective means shining by its own light. #{DO_NOT_COPY_ENGLISH}",
        'similarly'              => "The English adverb means likewise or analogously. #{DO_NOT_COPY_ENGLISH}",
        'therefore'              => "The English adverb means for that reason. #{DO_NOT_COPY_ENGLISH}",
        'some examples are'      => 'This phrase introduces a list of examples. Translate every word of the phrase.',
        'those endeavours'       => "The English phrase \"those endeavours\" means that kind of work. #{DO_NOT_COPY_ENGLISH}",
        'without any delay'      => "The English phrase \"without any delay\" means immediately. #{DO_NOT_COPY_ENGLISH}",
        'trifarious'             => "The English adjective \"trifarious\" means having three aspects. #{DO_NOT_COPY_ENGLISH}"
      }.freeze

      private

      def prompt(text, from:, to:)
        instructions = [
          "Translate the #{Language::Name.english(from)} prose in the following text into #{Language::Name.target(to)}.",
          'Preserve every sentence and line break; do not omit or repeat text.',
          'Choose one direct translation; do not output alternatives, annotations, or parenthetical variants.',
          QUOTED_PROSE_INSTRUCTION,
          delimiter_instruction(text)
        ]
        tags = tag_instruction(text)
        instructions << tags if tags
        placeholders = placeholder_instruction(text)
        instructions << placeholders if placeholders
        instructions.concat(source_term_hints(text))
        instructions << 'Only output the translated result without any additional explanation:'
        "#{instructions.join("\n")}\n\n#{text}"
      end

      def repair_prompt(source, invalid:, issue:, tokens:, from:, to:)
        source_only = issue.match?(
          /source prose unchanged|omitted source prose|source-language (?:span|word)|retained English phrase|foreign-script character/
        )
        return untranslated_repair_prompt(source, from: from, to: to) if source_only

        meanings = tokens.map do |placeholder, value|
          plain = CGI.unescapeHTML(value.gsub(/<[^>]+>|⟦U[0-9a-f]{64}⟧/, ' ')).strip
          plain = plain.unicode_normalize(:nfd).gsub(/\p{M}/, '')
          "#{placeholder} = #{plain.empty? ? 'protected markup' : plain}"
        end
        <<~PROMPT.strip
          Correct the invalid #{Language::Name.target(to)} translation below.
          Validation failure: #{issue}
          Translate every #{Language::Name.english(from)} prose word outside placeholders; do not copy source-language prose.
          Preserve every sentence and line break; do not omit or repeat text.
          Choose one direct translation; do not output alternatives, annotations, or parenthetical variants.
          #{QUOTED_PROSE_INSTRUCTION}
          #{delimiter_instruction(source)}
          #{tag_instruction(source)}
          #{placeholder_instruction(source)}
          Use these meanings only to understand the grammar; output the placeholders, not their meanings:
          #{meanings.join("\n")}
          Copy every placeholder literally; never replace it with its meaning.
          Only output the translation without any additional explanation.

          #{Language::Name.english(from)} source:
          #{source}

          Invalid translation to correct:
          #{invalid}
        PROMPT
      end

      def untranslated_repair_prompt(source, from:, to:)
        instructions = [
          "Translate this #{Language::Name.english(from)} sentence completely into #{Language::Name.target(to)}.",
          "Do not output any #{Language::Name.english(from)} words.",
          'Preserve every sentence and line break; do not omit or repeat text.',
          'Choose one direct translation; do not output alternatives, annotations, or parenthetical variants.',
          QUOTED_PROSE_INSTRUCTION,
          delimiter_instruction(source)
        ]
        tags = tag_instruction(source)
        instructions << tags if tags
        placeholders = placeholder_instruction(source)
        instructions << placeholders if placeholders
        instructions.concat(source_term_hints(source))
        instructions << 'Only output the translation without any additional explanation:'
        "#{instructions.join("\n")}\n\n#{source}"
      end

      def source_term_hints(source)
        SOURCE_TERM_HINTS.filter_map do |term, hint|
          hint if source.to_s.match?(/\b#{Regexp.escape(term)}\b/i)
        end
      end

      def delimiter_instruction(source)
        counts = %w[( ) [ ] { }].map { |delimiter| %Q{"#{delimiter}"=#{source.count(delimiter)}} }
        "Preserve exact delimiter counts, including unmatched delimiters: #{counts.join(', ')}. " \
          'Do not balance or correct them.'
      end

      def tag_instruction(source)
        tags = source.scan(/<[^>]+>/)
        return if tags.empty?

        "Preserve this exact HTML tag sequence without adding, omitting, changing, or reordering tags: #{tags.join(', ')}."
      end

      def placeholder_instruction(source)
        placeholders = source.scan(WIRE_PLACEHOLDER)
        return if placeholders.empty?

        'Preserve exactly these placeholder occurrences, including every repeated entry, without translating or ' \
          "renumbering them: #{placeholders.join(', ')}. Do not append this list to the translation."
      end
    end
  end
end
