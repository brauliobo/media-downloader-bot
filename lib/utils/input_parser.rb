require 'addressable/uri'
require 'uri'

module Utils
  class InputParser
    Result = Data.define(:url, :opts)
    URL_TOKEN_REGEXP = %r{\A(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:[/?#][^\s]*)?\z}i

    def self.parse(line)
      args = line.to_s.split(/[[:space:]]+/)
      url = nil
      
      if (url_index = args.index { |arg| url_like?(arg) })
        url_str = args[url_index]
        args    = args[(url_index + 1)..] || []
        url_str = "https://#{url_str}" unless url_str.match?(%r{\Ahttps?://}i)
        url     = Addressable::URI.parse(url_str) rescue nil
      end

      opts = args.each_with_object({}) do |a, h|
        k, v = a.split('=', 2)
        h[k] = v || 1
      end

      Result.new(url: url, opts: opts)
    end

    def self.url_like?(token)
      token.to_s.match?(URI::DEFAULT_PARSER.make_regexp) || token.to_s.match?(URL_TOKEN_REGEXP)
    end
  end
end
