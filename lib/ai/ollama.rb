require 'base64'
require 'mechanize'
require 'timeout'
require 'json'
require_relative '../manager'
require_relative '../exts/sym_mash'

module AI
  class Ollama
    API   = ENV['OLLAMA_HOST']
    MODEL = ENV['OLLAMA_OCR_MODEL']

    def self.chat(messages, timeout: 30, format: nil)
      payload = { model: MODEL, stream: false, options: {temperature: 0.0}, messages: messages }
      payload[:format] = format if format
      res = Timeout.timeout(timeout) { Manager.http.post "#{API}/api/chat", payload.to_json }
      SymMash.new(JSON.parse(res.body)).dig(:message, :content).to_s.strip
    end
  end
end

