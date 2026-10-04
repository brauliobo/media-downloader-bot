module AI
  class Ollama
    API           = ENV['OLLAMA_HOST']
    DEFAULT_MODEL = ENV['OLLAMA_MODEL'] || 'gemma4:e2b'
    MODEL         = ENV['OLLAMA_OCR_MODEL'] || DEFAULT_MODEL
    PROMPT_MODEL  = ENV['OLLAMA_LANGUAGE_MODEL'] || DEFAULT_MODEL

    def self.prompt(text, model: PROMPT_MODEL)
      chat([{ role: :user, content: text }], model: model)
    end

    def self.chat(messages, format: nil, model: MODEL)
      payload = { model: MODEL, stream: false, options: {temperature: 0.0}, messages: messages }
      payload[:model] = model if model
      payload[:format] = format if format
      res = Utils::HTTP.post "#{API}/api/chat", payload.to_json
      raise "Ollama API HTTP error: #{res.code}" unless res.code.to_i == 200
      parsed = SymMash.new JSON.parse res.body
      if parsed.error
        raise "Ollama API error: #{parsed.error}"
      end
      content = parsed.dig(:message, :content).to_s.strip
      if content.match?(/execution expired/i)
        raise "Ollama execution expired"
      end
      content
    end
  end
end
