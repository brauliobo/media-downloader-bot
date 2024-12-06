class Translator
  module Madlad400

    # based on https://github.com/brauliobo/candle
    mattr_accessor :api_host
    mattr_accessor :api_path
    self.api_host = ENV['CANDLE_MADLAD400_HOST']
    self.api_path = '/completions'

    mattr_accessor :http
    self.http = Mechanize.new
    self.http.read_timeout = 10.minutes.to_i

    HEADERS = { 
      'Content-Type' => 'application/json',
    }

    def translate _text, to:, from: nil
      text  = Array.wrap(_text).map{ |t| "<2#{to}> #{t}" }
      res   = http.post "#{api_host}#{api_path}", {prompt: text}.to_json, HEADERS
      res   = JSON.parse res.body
      trans = res['content']
      return trans.first if _text.is_a? String and trans.is_a? Array
      trans
    end

  end
end
