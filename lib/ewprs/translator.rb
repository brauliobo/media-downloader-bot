require 'cgi'
require 'concurrent'
require 'iso-639'

module Ewprs
  class Translator
    API_PATH = '/v1/chat/completions'
    HEADERS  = {'Content-Type' => 'application/json'}.freeze
    INTERNAL_PLACEHOLDER = /__P\d{4}__/
    CHARACTER_REFERENCE = /&(?:#\d+|#x[\da-f]+|[a-z][\w]+);?/i
    WIRE_PLACEHOLDER     = /ZXQEWPRS[PE]\d+(?:ZXQ)?/
    XML_PLACEHOLDER      = %r{<ewprs-p id="(\d+)"\s*/>|<ewprs-p id="(\d+)"\s*>.*?</ewprs-p>}im
    XML_QUOTE_PLACEHOLDER = /<ewprs-(?:single-)?quote-(?:open|close) id="\d+"\s*\/>/i
    EDITORIAL_TAG         = %r{<span data-ewprs="[12][12]">|</span>}i
    SMART_QUOTE_REFERENCE = {
      '&ldquo;' => 'quote-open', '&rdquo;' => 'quote-close',
      '&lsquo;' => 'single-quote-open', '&rsquo;' => 'single-quote-close'
    }.freeze
    NATURAL_CHARACTER_REFERENCE = {
      '&ndash;' => '–', '&mdash;' => '—',
      '&ldquo;' => '“', '&rdquo;' => '”',
      '&lsquo;' => '‘', '&rsquo;' => '’'
    }.freeze
    SMART_QUOTE          = /(?:&(?:l|r)[sd]quo;|[“”«»])/i
    NATURAL_SMART_QUOTE  = /[“”„‟«»‘’‚‛‹›]/
    TRANSLATION_BOUNDARY = /(#{SMART_QUOTE}|<span data-ewprs="[12][12]">|<\/span>)/i
    QUOTED_PROSE_INSTRUCTION = 'Translate prose inside quotation marks too; quotation marks do not denote protected text.'
    SOURCE_TERM_HINTS = {
      'all of North Bengal'    => 'Interpret the phrase "all of North Bengal" to mean every part of the geographic ' \
                                  'region North Bengal. Translate that meaning; do not copy this explanation.',
      'all of South East Asia' => 'Before translating, interpret the exact English phrase "all of South East Asia" ' \
                                  'as "throughout Southeast Asia".',
      'anchoring'              => 'Interpret the English word "anchoring" as "firmly establishing".',
      'cause your downfall'    => 'Interpret the English phrase "cause your downfall" as "bring ruin upon a person".',
      'definition'             => 'Interpret the English word "definition" as "statement of meaning".',
      'descended'              => 'Interpret the English adjective "descended" as "derived from an earlier language".',
      'each of these five'     => 'Interpret the English phrase "each of these five" as "every one of these five".',
      'edition'                => 'In bibliographic prose, translate "Edition" as the target-language word for a ' \
                                  'publication edition.',
      'extro-internal'         => 'Interpret the English adjective "extro-internal" as "from the external toward the internal".',
      'feeder'                 => 'Interpret the English noun "feeder" as "one who nourishes or supplies".',
      'illiterate'             => 'Interpret the English adjective "illiterate" as "unable to read or write".',
      'illustrative'           => 'Interpret the English adjective "illustrative" as "serving as examples".',
      'inculcating'            => 'Interpret the English verb "inculcating" as "firmly instilling".',
      'inject'                 => 'Interpret the English verb "inject" as "introduce or instill".',
      'linseed'                => 'Interpret the English noun "linseed" as "flax seed".',
      'literally'              => 'Interpret the English adverb "literally" as "in the literal sense".',
      'respectively'           => 'Interpret the English adverb "respectively" as "in the same order".',
      'similarly'              => 'Interpret the English adverb "similarly" as "in the same way".',
      'some examples are'      => 'This phrase introduces a list of examples. Translate every word of the phrase.',
      'those endeavours'       => 'Interpret the English phrase "those endeavours" as "such efforts".',
      'without any delay'      => 'Interpret the English phrase "without any delay" as "immediately".',
      'trifarious'             => 'Interpret the English adjective "trifarious" as "threefold".'
    }.freeze
    TRANSPORT_ERRORS      = [EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED].freeze
    RETRYABLE_HTTP_STATUS = [500, 502, 503, 504].freeze
    TRANSPORT_RETRIES     = 3
    TRANSPORT_RETRY_DELAY = 2

    attr_reader :jobs

    def initialize(jobs: nil)
      @jobs = Integer(jobs || ENV.fetch('HYMT2_CONCURRENCY', 8))
      raise ArgumentError, 'jobs must be positive' unless @jobs.positive?

      @request_semaphore = Concurrent::Semaphore.new(@jobs)
    end

    def translate_markup(text, from: 'en', to:)
      texts = text.is_a?(String) ? [text] : Array(text)
      return [] if texts.empty?

      executor = Concurrent::FixedThreadPool.new([concurrency, texts.size].min)
      futures = texts.map do |source|
        Concurrent::Promises.future_on(executor, source) do |value|
          translate_one(value, from: from, to: to)
        end
      end
      translations = Concurrent::Promises.zip(*futures).value!
      text.is_a?(String) ? translations.first : translations
    ensure
      executor&.shutdown
      executor&.wait_for_termination
    end

    def repair_markup(source, invalid:, issue:, tokens:, from: 'en', to:)
      placeholders = placeholder_mapping(source)
      encoded_source = replace_placeholders(source, placeholders)
      encoded_tokens = tokens.to_h do |marker, value|
        [placeholders.fetch(marker, marker), replace_placeholders(value, placeholders)]
      end
      output = complete(
        repair_prompt(
          encoded_source,
          invalid: replace_placeholders(invalid, placeholders), issue: issue,
          tokens: encoded_tokens, from: from, to: to
        )
      )
      output = remove_echoed_source(output, encoded_source)
      restore_placeholders(output, placeholders)
    end

    def translate_preserving_smart_quotes(text, from: 'en', to:)
      parts = text.to_s.split(TRANSLATION_BOUNDARY)
      prose = parts.each_index.filter_map do |index|
        next if index.odd?

        core = parts[index].strip
        core unless core.empty?
      end
      translated = Array(translate_markup(prose, from: from, to: to)).each
      parts.each_with_index.map do |part, index|
        next part if index.odd? || part.strip.empty?

        part.sub(part.strip, translated.next.gsub(SMART_QUOTE, ''))
      end.join
    end

    def translate_preserving_editorial_tags(text, from: 'en', to:)
      parts = text.to_s.split(/(#{EDITORIAL_TAG})/)
      prose = parts.each_index.filter_map do |index|
        next if index.odd?

        core = parts[index].strip
        core unless core.empty?
      end
      translated = Array(translate_markup(prose, from: from, to: to)).each
      parts.each_with_index.map do |part, index|
        next part if index.odd? || part.strip.empty?

        part.sub(part.strip, translated.next)
      end.join
    end

    def translate_preserving_placeholders(text, values: {}, from: 'en', to:)
      output = translate_with_xml_placeholders(text, values: values, from: from, to: to)
      expected = text.to_s.scan(INTERNAL_PLACEHOLDER).tally
      if output.scan(INTERNAL_PLACEHOLDER).tally == expected
        return output unless output == text.to_s

        natural = translate_with_natural_placeholders(text, values: values, from: from, to: to)
        return natural if natural && natural != text.to_s

        return translate_between_placeholders(text, from: from, to: to)
      end

      clauses = text.to_s.split(/([,;][ \t]*)/)
      projected = clauses.each_with_index.map do |clause, index|
        index.odd? ? clause : translate_with_xml_placeholders(clause, values: values, from: from, to: to)
      end.join
      return projected if projected.scan(INTERNAL_PLACEHOLDER).tally == expected

      translate_between_placeholders(text, from: from, to: to)
    end

    def translate_preserving_character_references(text, from: 'en', to:)
      natural = text.to_s.gsub(CHARACTER_REFERENCE) do
        natural_character_reference(Regexp.last_match[0])
      end
      output = translate_one(natural, from: from, to: to)
      restore_natural_character_references(output, text)
    end

    def translate_by_clauses(text, from: 'en', to:)
      parts = text.to_s.split(/([,;][ \t]*)/)
      indexes = parts.each_index.select { |index| index.even? && !parts[index].strip.empty? }
      sources = indexes.map { |index| parts[index].strip }
      translations = Array(translate_markup(sources, from: from, to: to))
      sources.each_with_index do |source, index|
        translated = translations[index]
        if translated == source && source.match?(/\s/)
          leading, remainder = source.split(/\s+/, 2)
          translated_leading, translated_remainder = translate_markup([leading, remainder], from: from, to: to)
          translated = "#{translated_leading} #{translated_remainder}" if translated_remainder != remainder
        end
        translated = translated.sub(/[.!?]\z/, '') unless source.match?(/[.!?]\z/)
        if index.positive? && to.to_s.downcase == 'de' && source.match?(/\A\p{Ll}/u)
          translated = translated.sub(/\A(?:Das|Der|Die|Ein|Eine|Er|Es)\b/) { |word| word.downcase }
        end
        parts[indexes[index]] = parts[indexes[index]].sub(parts[indexes[index]].strip, translated)
      end
      parts.join
    end

    def translate_preserving_placeholder_order(text, from: 'en', to:)
      translate_between_placeholders(text, from: from, to: to)
    end

    private

    def translate_between_placeholders(text, from:, to:)
      parts = text.to_s.split(/(#{INTERNAL_PLACEHOLDER})/)
      prose = parts.each_index.filter_map do |index|
        next if index.odd?

        core = parts[index].strip
        core unless core.empty?
      end
      translated = Array(translate_markup(prose, from: from, to: to)).each
      parts.each_with_index.map do |part, index|
        next part if index.odd? || part.strip.empty?

        part.sub(part.strip, translated.next)
      end.join
    end

    def translate_with_natural_placeholders(text, values:, from:, to:)
      placeholders = text.to_s.scan(INTERNAL_PLACEHOLDER).uniq
      natural_values = placeholders.to_h do |placeholder|
        value = natural_placeholder_value(values[placeholder])
        return if value.empty?

        [placeholder, value]
      end
      expanded = text.to_s.gsub(INTERNAL_PLACEHOLDER, natural_values)
      expanded = expanded.gsub(CHARACTER_REFERENCE) { natural_character_reference(Regexp.last_match[0]) }
      projected = translate_one(expanded, from: from, to: to)

      natural_values.sort_by { |_placeholder, value| -value.length }.each do |placeholder, value|
        text.to_s.scan(placeholder).size.times do
          return unless projected.sub!(natural_phrase_pattern(value), placeholder)
        end
      end
      restore_natural_character_references(projected, text)
    end

    def natural_placeholder_value(value)
      plain = value.to_s.gsub(/<[^>]+>|⟦U[0-9a-f]{64}⟧/, ' ')
      plain = plain.gsub(CHARACTER_REFERENCE) { natural_character_reference(Regexp.last_match[0]) }
      plain.unicode_normalize(:nfd).gsub(/\p{M}/u, '').strip
    end

    def natural_character_reference(reference)
      NATURAL_CHARACTER_REFERENCE.fetch(reference.downcase) { CGI.unescapeHTML(reference) }
    end

    def natural_phrase_pattern(value)
      opening = value.match?(/\A\p{L}/u) ? '(?<!\p{L})' : ''
      closing = value.match?(/\p{L}\z/u) ? '(?!\p{L})' : ''
      Regexp.new("#{opening}#{Regexp.escape(value)}#{closing}", Regexp::IGNORECASE)
    end

    def restore_natural_character_references(output, source)
      source.to_s.scan(CHARACTER_REFERENCE).each_with_object(output) do |reference, restored|
        natural = natural_character_reference(reference)
        next if natural == reference

        pattern = SMART_QUOTE_REFERENCE.key?(reference.downcase) ? NATURAL_SMART_QUOTE : Regexp.new(Regexp.escape(natural))
        return unless restored.sub!(pattern, reference)
      end
    end

    def translate_with_xml_placeholders(text, values:, from:, to:)
      encoded, replacements = encode_character_references(text)
      encoded = encoded.gsub(INTERNAL_PLACEHOLDER) do |placeholder|
        id = placeholder[/\d+/].to_i
        value = values[placeholder]
        semantic = CGI.unescapeHTML(value.to_s.gsub(/<[^>]+>|⟦U[0-9a-f]{64}⟧/, ' ')).strip
        if semantic.empty?
          %(<ewprs-p id="#{id}"/>)
        else
          %(<ewprs-p id="#{id}">#{CGI.escapeHTML(semantic)}</ewprs-p>)
        end
      end
      output = complete(prompt(encoded, from: from, to: to))
      output = remove_echoed_source(output, encoded)
      output = output.gsub(XML_PLACEHOLDER) do
        format('__P%04d__', Regexp.last_match.captures.compact.first.to_i)
      end
      restore_encoded_placeholders(output, replacements)
    end

    def translate_one(text, from:, to:)
      encoded, placeholders = encode_translation_placeholders(text)
      output = complete(prompt(encoded, from: from, to: to))
      output = remove_echoed_source(output, encoded)
      restore_encoded_placeholders(output, placeholders)
    rescue Mechanize::ResponseCodeError => error
      raise unless error.response_code.to_i == 500 && text.to_s.scan(SMART_QUOTE).size.odd?

      translate_preserving_smart_quotes(text, from: from, to: to)
    end

    def remove_echoed_source(output, source)
      stripped = output.to_s.sub(/\A#{Regexp.escape(source.to_s.strip)}[ \t]*(?:\r?\n[ \t]*)+/, '')
      stripped.empty? ? output : stripped
    end

    def encode_translation_placeholders(text)
      encoded, replacements = encode_character_references(text)
      encoded = encoded.gsub(INTERNAL_PLACEHOLDER) do |placeholder|
        marker = "ZXQEWPRSP#{placeholder[/\d+/].to_i}ZXQ"
        replacements[marker] = placeholder
        marker
      end
      [encoded, replacements]
    end

    def encode_character_references(text)
      replacements = {}
      encoded = text.to_s.gsub(CHARACTER_REFERENCE).with_index do |reference, index|
        marker = encoded_character_reference(reference, index)
        replacements[marker] = reference
        marker
      end
      [encoded, replacements]
    end

    def restore_encoded_placeholders(text, replacements)
      text.to_s.gsub(/#{WIRE_PLACEHOLDER}|#{XML_QUOTE_PLACEHOLDER}/) do |marker|
        replacements.fetch(complete_wire_placeholder(marker), marker)
      end
    end

    def placeholder_mapping(text)
      placeholders = text.to_s.scan(INTERNAL_PLACEHOLDER).uniq.to_h do |marker|
        [marker, "ZXQEWPRSP#{marker[/\d+/].to_i}ZXQ"]
      end
      text.to_s.scan(CHARACTER_REFERENCE).uniq.each_with_index do |reference, index|
        placeholders[reference] = encoded_character_reference(reference, index)
      end
      placeholders
    end

    def replace_placeholders(text, placeholders)
      text.to_s.gsub(/#{INTERNAL_PLACEHOLDER}|#{CHARACTER_REFERENCE}/) do |marker|
        placeholders.fetch(marker, marker)
      end
    end

    def restore_placeholders(text, placeholders)
      internal = placeholders.invert
      text.to_s.gsub(/#{WIRE_PLACEHOLDER}|#{XML_QUOTE_PLACEHOLDER}/) do |marker|
        internal.fetch(complete_wire_placeholder(marker), marker)
      end
    end

    def complete_wire_placeholder(marker)
      marker.start_with?('ZXQEWPRS') && !marker.end_with?('ZXQ') ? "#{marker}ZXQ" : marker
    end

    def encoded_character_reference(reference, index)
      quote = SMART_QUOTE_REFERENCE[reference.downcase]
      quote ? %(<ewprs-#{quote} id="#{index + 1}"/>) : "ZXQEWPRSE#{index + 1}ZXQ"
    end

    def complete(prompt)
      options = {
        model:       model,
        messages:    [{role: :user, content: prompt}],
        temperature: 0,
        max_tokens:  max_tokens,
      }
      retries = 0
      begin
        response = @request_semaphore.acquire do
          Utils::HTTP.post "#{host.delete_suffix('/')}#{API_PATH}", options.to_json, HEADERS
        end
      rescue *TRANSPORT_ERRORS
        raise if retries >= TRANSPORT_RETRIES

        retries += 1
        sleep TRANSPORT_RETRY_DELAY
        retry
      rescue Mechanize::ResponseCodeError => error
        raise unless RETRYABLE_HTTP_STATUS.include?(error.response_code.to_i)
        raise if retries >= TRANSPORT_RETRIES

        retries += 1
        sleep TRANSPORT_RETRY_DELAY
        retry
      end
      JSON.parse(response.body).fetch('choices').fetch(0).fetch('message').fetch('content').strip
    end

    def prompt(text, from:, to:)
      instructions = [
        "Translate the #{language_name(from)} prose in the following text into #{target_language_name(to)}.",
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
        Correct the invalid #{target_language_name(to)} translation below.
        Validation failure: #{issue}
        Translate every #{language_name(from)} prose word outside placeholders; do not copy source-language prose.
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

        #{language_name(from)} source:
        #{source}

        Invalid translation to correct:
        #{invalid}
      PROMPT
    end

    def untranslated_repair_prompt(source, from:, to:)
      instructions = [
        "Translate this #{language_name(from)} sentence completely into #{target_language_name(to)}.",
        "Do not output any #{language_name(from)} words.",
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

    def target_language_name(code)
      code = code.to_s.downcase
      return 'Brazilian Portuguese' if code == 'pt'
      return 'Simplified Chinese' if code == 'zh'

      language_name(code)
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

    def language_name(code)
      code = code.to_s.downcase
      ISO_639.find_by_code(code)&.english_name&.split(';')&.first || code
    end

    def host
      ENV.fetch('HYMT2_HOST', 'http://127.0.0.1:12002')
    end

    def model
      ENV.fetch('HYMT2_MODEL', 'Hy-MT2-7B-Q4_K_M.gguf')
    end

    def concurrency
      jobs
    end

    def max_tokens
      [ENV.fetch('EWPRS_TRANSLATION_MAX_TOKENS', 2048).to_i, 1].max
    end
  end
end
