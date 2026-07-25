require 'cgi'
require 'concurrent'
require 'iso-639'

module Ewprs
  class Translator
    API_PATH = '/v1/chat/completions'
    HEADERS  = {'Content-Type' => 'application/json'}.freeze

    def translate_markup(text, to:)
      texts = text.is_a?(String) ? [text] : Array(text)
      return [] if texts.empty?

      executor = Concurrent::FixedThreadPool.new([concurrency, texts.size].min)
      futures = texts.map do |source|
        Concurrent::Promises.future_on(executor, source) do |value|
          translate_one(value, to: to)
        end
      end
      translations = Concurrent::Promises.zip(*futures).value!
      text.is_a?(String) ? translations.first : translations
    ensure
      executor&.shutdown
      executor&.wait_for_termination
    end

    def repair_markup(source, tokens:, to:)
      complete(repair_prompt(source, tokens: tokens, to: to))
    end

    private

    def translate_one(text, to:)
      complete(prompt(text, to: to))
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

    def prompt(text, to:)
      instructions = ["Translate the English prose in the following text into #{target_language_name(to)}."]
      placeholders = text.scan(/__P\d{4}__/).uniq
      unless placeholders.empty?
        instructions << 'Output each placeholder exactly once without adding, omitting, duplicating, or renumbering it: ' \
                        "#{placeholders.join(', ')}."
      end
      instructions << 'Only output the translated result without any additional explanation:'
      "#{instructions.join("\n")}\n\n#{text}"
    end

    def repair_prompt(source, tokens:, to:)
      meanings = tokens.map do |placeholder, value|
        plain = CGI.unescapeHTML(value.gsub(/<[^>]+>|⟦U[0-9a-f]{64}⟧/, ' ')).strip
        plain = plain.unicode_normalize(:nfd).gsub(/\p{M}/, '')
        "#{placeholder} = #{plain.empty? ? 'protected markup' : plain}"
      end
      <<~PROMPT.strip
        Translate the English source into #{target_language_name(to)}.
        Output each placeholder exactly once and do not add, omit, duplicate, translate, or renumber placeholders.
        Use these meanings only to understand the grammar; output the placeholders, not their meanings:
        #{meanings.join("\n")}
        Only output the translation without any additional explanation.

        English source:
        #{source}
      PROMPT
    end

    def target_language_name(code)
      code = code.to_s.downcase
      return 'Brazilian Portuguese' if code == 'pt'
      return 'Simplified Chinese' if code == 'zh'

      ISO_639.find_by_code(code)&.english_name&.split(';')&.first || code
    end

    def host
      ENV.fetch('HYMT2_HOST', 'http://127.0.0.1:12002')
    end

    def model
      ENV.fetch('HYMT2_MODEL', 'Hy-MT2-7B-Q4_K_M.gguf')
    end

    def concurrency
      [ENV.fetch('HYMT2_CONCURRENCY', 8).to_i, 1].max
    end

    def max_tokens
      [ENV.fetch('EWPRS_TRANSLATION_MAX_TOKENS', 2048).to_i, 1].max
    end
  end
end
