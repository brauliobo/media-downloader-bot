module AI
  class Ollama
    API           = ENV['OLLAMA_HOST']
    DEFAULT_MODEL = ENV['OLLAMA_MODEL'] || 'gemma4:e2b'
    MODEL         = ENV['OLLAMA_OCR_MODEL'] || DEFAULT_MODEL
    PROMPT_MODEL  = ENV['OLLAMA_LANGUAGE_MODEL'] || DEFAULT_MODEL
    # One thread: the GPU does the work, more only spin on the CPU. Every caller sends the same options, or Ollama reloads the model.
    # A page that makes the model loop at temperature 0 would otherwise generate until the timeout, holding the GPU for 15 minutes.
    OPTIONS       = { temperature: 0.0, num_thread: 1, num_predict: ENV.fetch('OLLAMA_NUM_PREDICT', 8192).to_i }
    # What a reply that hit the cap is asked again with: sampling only, the model stays loaded.
    LOOP_BREAKER  = { temperature: 0.3, repeat_penalty: 1.3 }
    TIMEOUT       = ENV.fetch('OLLAMA_TIMEOUT', 15.minutes).to_i

    def self.prompt(text, model: PROMPT_MODEL)
      chat([{ role: :user, content: text }], model: model)
    end

    def self.chat(messages, format: nil, model: MODEL)
      payload = { model: MODEL, stream: false, options: OPTIONS, messages: messages }
      payload[:model] = model if model
      payload[:format] = format if format
      again  = -> { request(payload.merge(options: OPTIONS.merge(LOOP_BREAKER))) }
      parsed = begin
        request(payload)
      rescue Mechanize::ResponseCodeError => e
        raise unless e.response_code == '500' # Ollama fails some replies at temperature 0 the same way every time

        again.call
      end
      parsed = again.call if cut?(parsed)
      raise "Ollama output cut at #{OPTIONS[:num_predict]} tokens, the model is looping" if cut?(parsed)
      content = parsed.dig(:message, :content).to_s.strip
      if content.match?(/execution expired/i)
        raise "Ollama execution expired"
      end
      content
    end

    def self.cut?(parsed) = parsed.done_reason == 'length'

    def self.request(payload)
      Utils::HTTP.client(timeout: TIMEOUT) # the thread's agent keeps the timeout the last service asked of it, a TTS call leaves it 2 minutes
      res = Utils::HTTP.post "#{API}/api/chat", payload.to_json
      raise "Ollama API HTTP error: #{res.code}" unless res.code.to_i == 200
      parsed = SymMash.new JSON.parse res.body
      raise "Ollama API error: #{parsed.error}" if parsed.error
      parsed
    end
    private_class_method :request
  end
end
