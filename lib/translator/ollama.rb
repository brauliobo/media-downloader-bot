class Translator
  module Ollama

    API   = ENV['OLLAMA_HOST']
    MODEL = ENV['OLLAMA_MODEL']

    JSON_SCHEMA = {
      type: :object,
      properties: {
        translations: {
          type: :array,
          description: "An array of translated strings, corresponding to the user's input.",
          items: {
            type: :string,
            description: 'The translated text.'
          }
        }
      },
      required: ["translations"]
    }

    LANG_MAP = {
      pt: 'Brazilian Portuguese',
    }

    mattr_accessor :http
    self.http = Mechanize.new

    def translate text, from:, to:
      to = LANG_MAP[to.to_sym] || to

      system_message_content = {
        task: "You are an expert translator. Translate the texts in `texts_to_translate` to the `target_language`.",
        target_language: to,
        texts_to_translate: Array(text)
      }.to_json

      opts = {
        model: MODEL,
        temperature: 0,
        format: JSON_SCHEMA,
        stream: false,
        messages: [
          { role: :system, content: system_message_content },
          { role: :user, content: 'Translate the content as instructed in the system message.' }
        ]
      }
      res  = http.post "#{API}/api/chat", opts.to_json
      res  = SymMash.new JSON.parse res.body
      res  = SymMash.new JSON.parse res.message.content
      tr   = res.translations
      return tr.first if text.is_a? String
      tr
    end

  end
end
