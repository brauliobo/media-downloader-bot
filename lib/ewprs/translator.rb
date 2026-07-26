require 'cgi'
require 'concurrent'
require 'iso-639'

module Ewprs
  class Translator
    API_PATH = '/v1/chat/completions'
    HEADERS  = {'Content-Type' => 'application/json'}.freeze

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
      complete(repair_prompt(source, invalid: invalid, issue: issue, tokens: tokens, from: from, to: to))
    end

    private

    def translate_one(text, from:, to:)
      complete(prompt(text, from: from, to: to))
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
      placeholders = source.scan(/__P\d{4}__/).uniq
      copy = " Copy #{placeholders.join(', ')} exactly." unless placeholders.empty?
      "Translate this #{language_name(from)} sentence completely into #{target_language_name(to)}. " \
        "Do not output any #{language_name(from)} words.#{copy} Only output the translation:\n#{source}"
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
      placeholders = source.scan(/__P\d{4}__/)
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
