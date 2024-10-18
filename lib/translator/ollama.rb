class Translator
  module Ollama

    API   = ENV['OLLAMA_HOST']
    MODEL = ENV['OLLAMA_MODEL']

    SYS = <<-EOP
You are a professional content translator to the %{lang} language. Your task is only to translate. Return only the translations of the prompts. Preserve endings, closings, thanks, subject, numbers, all details, meaning, semantics, verb tenses, format, lines, symbols, and structure of the content. Return the translations as a JSON array named \"translations\", where each translation corresponds to each user message in the order they were provided."
EOP

    LANG_MAP = {
      pt: :pt_BR,
    }

    mattr_accessor :http
    self.http = Mechanize.new

    def translate text, from:, to:
      to   = LANG_MAP[to.to_sym] || to
      opts = {
        model: MODEL, format: 'json', stream: false,
        messages: [
          {role: :system, content: SYS % {lang: to}},
          *Array(text).map{ |t| {role: :user, content: t} },
        ],
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
