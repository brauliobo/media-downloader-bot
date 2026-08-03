require 'concurrent'
require 'iso-639'

class Translator
  module LlamacppApi

    API_PATH = '/v1/chat/completions'
    HEADERS  = {'Content-Type' => 'application/json'}.freeze

    def translate(_text, to:, from: nil)
      texts        = Array.wrap(_text)
      translations = translate_concurrently(texts, to: to)
      _text.is_a?(String) ? translations.first : translations
    end

    def translate_for_dubbing(_text, to:, from: nil, durations:)
      texts        = Array.wrap(_text)
      translations = translate_concurrently(
        texts,
        to:        to,
        durations: Array.wrap(durations),
        context:   texts
      )
      _text.is_a?(String) ? translations.first : translations
    end

    private

    def translate_concurrently(texts, to:, durations: nil, context: nil)
      return [] if texts.empty?

      executor = Concurrent::FixedThreadPool.new([llama_concurrency, texts.size].min)
      futures  = texts.map.with_index do |text, idx|
        Concurrent::Promises.future_on(executor, text, durations&.fetch(idx), context && context_for(context, idx)) do |segment, duration, nearby|
          prompt = if duration
            dubbing_translation_prompt(segment, to: to, duration: duration, context: nearby)
          else
            translation_prompt(segment, to: to)
          end
          chat_completion(prompt)
        end
      end
      Concurrent::Promises.zip(*futures).value!
    ensure
      executor&.shutdown
      executor&.wait_for_termination
    end

    def context_for(texts, index)
      nearby = []
      nearby << "Previous: #{texts[index - 1]}" if index.positive?
      nearby << "Next: #{texts[index + 1]}" if index < texts.length - 1
      nearby.join("\n").presence
    end

    def chat_completion(prompt)
      opts = {
        model:       llama_model,
        messages:    [{role: :user, content: prompt}],
        temperature: 0,
        max_tokens:  512,
      }
      response = Utils::HTTP.post "#{llama_api_host.delete_suffix('/')}#{API_PATH}", opts.to_json, HEADERS
      JSON.parse(response.body).fetch('choices').fetch(0).fetch('message').fetch('content').strip
    end

    def translation_prompt(text, to:)
      <<~PROMPT.strip
        Translate the following text into #{target_language_name(to)} by meaning and context, not word-for-word. Use the natural target-language sense and avoid false cognates or unrelated meanings. Output only the translated text itself; do not add a label, acknowledgement, quotation, or explanation:

        #{text}
      PROMPT
    end

    def dubbing_translation_prompt(text, to:, duration:, context: nil)
      <<~PROMPT.strip
        Translate the following dialogue into concise, natural spoken #{target_language_name(to)} for dubbing by meaning and context, not word-for-word. Avoid false cognates or unrelated meanings.
        Resolve ambiguous words using the main dialogue and nearby dialogue when provided. Translate only the main dialogue, not the context.
        Preserve the complete meaning, names, and numbers, but choose brief wording that can be spoken clearly in about #{format('%.1f', duration)} seconds.
        Output only the translated dialogue itself; do not add a label, acknowledgement, quotation, or explanation:

        #{context ? "Nearby dialogue for context:\n#{context}\n\n" : ''}Main dialogue:
        #{text}
      PROMPT
    end

    def target_language_name(code)
      code = code.to_s.downcase
      return 'Brazilian Portuguese' if code == 'pt'
      return 'Simplified Chinese' if code == 'zh'

      ISO_639.find_by_code(code)&.english_name&.split(';')&.first || code
    end

    def llama_api_host
      ENV['LLAMA_CPP_HOST'] || ENV.fetch('LLAMA_CPP_MADLAD400_HOST')
    end

    def llama_model
      ENV.fetch('LLAMA_CPP_MODEL', 'local-model')
    end

    def llama_concurrency
      [ENV.fetch('LLAMA_CPP_CONCURRENCY', 8).to_i, 1].max
    end

  end
end
