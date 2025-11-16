module AI
  class Ollama
    API   = ENV['OLLAMA_HOST']
    MODEL = ENV['OLLAMA_OCR_MODEL']

    def self.chat(messages, format: nil)
      payload = { model: MODEL, stream: false, options: {temperature: 0.0}, messages: messages }
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

