require 'cgi'
require 'concurrent'
require 'iso-639'
require 'net/http'

module Ewprs
  class Translator
    include Prompts
    include Placeholders

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
    # The model serves a few requests at a time and the router in front of it drops the ones that wait longer than its
    # read timeout, so the limit is shared by every translator of the process: books converted in parallel queue here.
    REQUEST_LIMITS = Concurrent::Map.new
    attr_reader :jobs

    def initialize(jobs: nil)
      @jobs = Integer(jobs || ENV.fetch('HYMT2_CONCURRENCY', 4))
      raise ArgumentError, 'jobs must be positive' unless @jobs.positive?

      @request_semaphore = REQUEST_LIMITS.compute_if_absent([host, @jobs]) { Concurrent::Semaphore.new(@jobs) }
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
        core unless core.empty? || core.match?(/\A[A-Za-z]\z/)
      end
      translated = Array(translate_markup(prose, from: from, to: to)).each
      parts.each_with_index.map do |part, index|
        next part if index.odd? || part.strip.empty? || part.strip.match?(/\A[A-Za-z]\z/)

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
        if output != text.to_s && letters?(output)
          return output
        end

        natural = translate_with_natural_placeholders(text, values: values, from: from, to: to)
        return natural if natural && natural != text.to_s && letters?(natural)

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
      parts = text.to_s.split(/([,;][ \t]*|[ \t]+\/[ \t]+)/)
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
        if index.positive? && to.to_s.downcase == 'de' && Text.lowercase?(source)
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

    def letters?(text)
      text.to_s.gsub(INTERNAL_PLACEHOLDER, '').match?(/\p{L}/u)
    end

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

    def complete(prompt)
      options = {
        model:       model,
        messages:    [{role: :user, content: prompt}],
        temperature: 0,
        max_tokens:  max_tokens,
      }
      response = @request_semaphore.acquire do
        Utils::HTTP.post Utils::HTTP.url(host, API_PATH), options.to_json, HEADERS
      end
      JSON.parse(response.body).fetch('choices').fetch(0).fetch('message').fetch('content').strip
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
