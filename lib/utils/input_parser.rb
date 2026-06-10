require 'addressable/uri'
require 'uri'

module Utils
  class InputParser
    Result = Data.define(:url, :opts)

    def self.parse(line)
      args = line.to_s.split(/[[:space:]]+/)
      url = nil
      
      if (url_index = args.index { |arg| arg.match?(URI::DEFAULT_PARSER.make_regexp) })
        url_str = args[url_index]
        args    = args[(url_index + 1)..] || []
        url     = Addressable::URI.parse(url_str) rescue nil
      end

      opts = args.each_with_object({}) do |a, h|
        k, v = a.split('=', 2)
        h[k] = v || 1
      end

      Result.new(url: url, opts: opts)
    end
  end
end
