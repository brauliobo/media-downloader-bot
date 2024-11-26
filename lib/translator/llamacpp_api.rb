class Translator
  class LlamacppApi

    class_attribute :api_host
    class_attribute :api_path
    self.api_path = '/v1/chat/completions'

    class_attribute :http
    self.http = Mechanize.new

    def translate text, to:, from: nil
      opts = {
        messages: text.map{ |t| {role: :user, content: t} },
      }
      res  = http.post "#{api_host}#{api_path}", opts.to_json
      res  = SymMash.new JSON.parse res.body
      res  = SymMash.new JSON.parse res.message.content
      return tr.first if text.is_a? String
      tr
    end

  end
end
