require 'cgi'
require 'concurrent'
require 'iso-639'

module Ewprs
  class Translator
    API_PATH = '/v1/chat/completions'
    HEADERS  = {'Content-Type' => 'application/json'}.freeze
    INTERNAL_PLACEHOLDER = /__P\d{4}__/
    CHARACTER_REFERENCE = /&(?:#\d+|#x[\da-f]+|[a-z][\w]+);?/i
    WIRE_PLACEHOLDER     = /\{\{EWPRS_[PE]\d+\}\}/
    SMART_QUOTE          = /(?:&(?:l|r)[sd]quo;|[“”«»])/i
    TRANSLATION_BOUNDARY = /(#{SMART_QUOTE}|<span data-ewprs="[12][12]">|<\/span>)/i

    attr_reader :jobs

    def initialize(jobs: nil)
      @jobs = Integer(jobs || ENV.fetch('HYMT2_CONCURRENCY', 8))
      raise ArgumentError, 'jobs must be positive' unless @jobs.positive?
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
      encoded_tokens = tokens.to_h do |marker, value|
        [placeholders.fetch(marker, marker), replace_placeholders(value, placeholders)]
      end
      output = complete(
        repair_prompt(
          replace_placeholders(source, placeholders),
          invalid: replace_placeholders(invalid, placeholders), issue: issue,
          tokens: encoded_tokens, from: from, to: to
        )
      )
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

    private

    def translate_one(text, from:, to:)
      encoded, placeholders = encode_translation_placeholders(text)
      output = complete(prompt(encoded, from: from, to: to))
      restore_encoded_placeholders(output, placeholders)
    end

    def encode_translation_placeholders(text)
      replacements = {}
      encoded = text.to_s.gsub(CHARACTER_REFERENCE).with_index do |reference, index|
        marker = "{{EWPRS_E#{index + 1}}}"
        replacements[marker] = reference
        marker
      end
      encoded = encoded.gsub(INTERNAL_PLACEHOLDER) do |placeholder|
        marker = "{{EWPRS_P#{placeholder[/\d+/].to_i}}}"
        replacements[marker] = placeholder
        marker
      end
      [encoded, replacements]
    end

    def restore_encoded_placeholders(text, replacements)
      text.to_s.gsub(WIRE_PLACEHOLDER) { |marker| replacements.fetch(marker, marker) }
    end

    def placeholder_mapping(text)
      placeholders = text.to_s.scan(INTERNAL_PLACEHOLDER).uniq.to_h do |marker|
        [marker, "{{EWPRS_P#{marker[/\d+/].to_i}}}"]
      end
      text.to_s.scan(CHARACTER_REFERENCE).uniq.each_with_index do |reference, index|
        placeholders[reference] = "{{EWPRS_E#{index + 1}}}"
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
      text.to_s.gsub(WIRE_PLACEHOLDER) { |marker| internal.fetch(marker, marker) }
    end

    def complete(prompt)
      options = {
        model:       model,
        messages:    [{role: :user, content: prompt}],
        temperature: 0,
        max_tokens:  max_tokens,
      }
      response = Utils::HTTP.post "#{host.delete_suffix('/')}#{API_PATH}", options.to_json, HEADERS
      JSON.parse(response.body).fetch('choices').fetch(0).fetch('message').fetch('content').strip
    end

    def prompt(text, from:, to:)
      instructions = [
        "Translate the #{language_name(from)} prose in the following text into #{target_language_name(to)}.",
        'Preserve every sentence and line break; do not omit or repeat text.',
        'Choose one direct translation; do not output alternatives, annotations, or parenthetical variants.',
        delimiter_instruction(text)
      ]
      tags = tag_instruction(text)
      instructions << tags if tags
      placeholders = placeholder_instruction(text)
      instructions << placeholders if placeholders
      instructions << 'Only output the translated result without any additional explanation:'
      "#{instructions.join("\n")}\n\n#{text}"
    end

    def repair_prompt(source, invalid:, issue:, tokens:, from:, to:)
      return untranslated_repair_prompt(source, from: from, to: to) if issue.match?(/source prose unchanged|source-language span/)

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
        delimiter_instruction(source)
      ]
      tags = tag_instruction(source)
      instructions << tags if tags
      placeholders = placeholder_instruction(source)
      instructions << placeholders if placeholders
      instructions << 'Only output the translation without any additional explanation:'
      "#{instructions.join("\n")}\n\n#{source}"
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
