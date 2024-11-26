class Translator
  class Madlad400 < LlamacppApi

    self.api_host = ENV['CANDLE_MADLAD400_HOST']
    self.api_path = '/completions'

    def translate text, to:, from: nil
      text = Array.wrap(text).map{ |t| "<2#{to}> #{t}" }
      res  = http.post "#{api_host}#{api_path}", opts.to_json
      text.map do |t|
        super(text, to:){ |res| res.content }
      end
    end

  end
end
