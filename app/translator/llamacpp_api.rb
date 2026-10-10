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

    def translate_for_dubbing(_text, to:, from: nil)
      texts        = Array.wrap(_text)
      translations = translate_concurrently(
        texts,
        to:      to,
        dubbing: true
      )
      _text.is_a?(String) ? translations.first : translations
    end

    private

    def translate_concurrently(texts, to:, dubbing: false)
      return [] if texts.empty?

      translations = Array.new(texts.size)
      texts.each_with_index.peach(reraise: true) do |text, idx|
        prompt = if dubbing
          dubbing_translation_prompt(text, to: to)
        else
          translation_prompt(text, to: to)
        end
        translations[idx] = chat_completion(prompt)
      end

      translations
    end

    def chat_completion(prompt)
      opts = {
        model:       llama_model,
        messages:    [{role: :user, content: prompt}],
        temperature: 0,
        max_tokens:  512,
      }
      response = Utils::HTTP.post Utils::HTTP.url(llama_api_host, API_PATH), opts.to_json, HEADERS
      JSON.parse(response.body).fetch('choices').fetch(0).fetch('message').fetch('content').strip
    end

    def translation_prompt(text, to:)
      <<~PROMPT.strip
        Translate the following text into #{Language::Name.target(to)} by meaning and context, not word-for-word. Use the natural target-language sense and avoid false cognates or unrelated meanings. Output only the translated text itself; do not add a label, acknowledgement, quotation, or explanation:

        #{text}
      PROMPT
    end

    def dubbing_translation_prompt(text, to:)
      <<~PROMPT.strip
        Translate all of the following dialogue faithfully and completely into natural spoken #{Language::Name.target(to)} for dubbing by meaning and context, not word-for-word. Avoid false cognates or unrelated meanings.
        Do not summarize, condense, shorten, or omit any information. Preserve every distinct statement, qualifier, repetition, name, and number.
        Output only the translated dialogue itself; do not add a label, acknowledgement, quotation, or explanation:

        Main dialogue:
        #{text}
      PROMPT
    end


    def llama_api_host
      ENV['LLAMA_CPP_HOST'] || ENV.fetch('LLAMA_CPP_MADLAD400_HOST')
    end

    def llama_model
      ENV.fetch('LLAMA_CPP_MODEL', 'local-model')
    end
  end
end
