require 'addressable/uri'
require 'uri'

module Utils
  class InputParser
    Result = Data.define(:url, :opts)
    URL_TOKEN_REGEXP = %r{\A(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:[/?#][^\s]*)?\z}i
    OPT_TOKEN_REGEXP = /\A[a-z][a-z0-9_.-]*(?:=.*)?\z/

    def self.parse(line)
      args = tokens(line)
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

    def self.input_text(ctx)
      ctx.line || message_text(ctx.msg)
    end

    def self.message_text(msg)
      text = msg.text if msg.respond_to?(:text)
      text = msg.caption if text.to_s.strip.empty? && msg.respond_to?(:caption)
      text.to_s
    end

    def self.message_lines(msg)
      message_text(msg).split("\n").reject { |line| line.to_s.strip.empty? }
    end

    def self.url_inputs(lines)
      lines = Array(lines).map(&:to_s)
      url_indexes = lines.each_index.select { |index| line_has_url?(lines[index]) }
      return [] if url_indexes.empty?

      base_opts = base_option_tokens(lines, url_indexes.first)

      url_indexes.map.with_index do |line_index, index|
        next_url_index = url_indexes[index + 1] || lines.size
        url_input(lines[line_index], lines[(line_index + 1)...next_url_index], base_opts)
      end
    end

    def self.line_has_url?(line)
      tokens(line).any? { |token| url_like?(token) }
    end

    def self.tokens(text)
      return text if text.is_a?(Array)

      text.to_s.split(/[[:space:]]+/)
    end

    def self.base_option_tokens(lines, first_url_index)
      return [] unless first_url_index.positive?

      option_tokens(lines.first)
    end

    def self.url_input(url_line, option_lines, base_opts)
      line_tokens = tokens(url_line)
      url_index   = line_tokens.index { |token| url_like?(token) }
      url_token   = line_tokens[url_index]
      line_opts   = line_tokens[(url_index + 1)..] || []
      opts        = base_opts + option_tokens(line_opts) + option_lines.flat_map { |line| option_tokens(line) }

      ([url_token] + opts).join(' ')
    end

    def self.option_tokens(value)
      tokens = tokens(value)
      return [] unless tokens.all? { |token| option_token?(token) }

      tokens
    end

    def self.option_token?(token)
      token.to_s.match?(OPT_TOKEN_REGEXP)
    end
  end
end
