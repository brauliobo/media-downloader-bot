require 'addressable/uri'

module Utils
  class Url
    HTTP_SCHEMES = %w[http https].freeze
    TOKEN_REGEXP = %r{\A(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:[/?#][^\s]*)?\z}i

    def self.parse(value)
      text = value.to_s.strip
      return if text.empty?

      text = "https://#{text}" unless text.match?(%r{\Ahttps?://}i)
      uri  = Addressable::URI.parse(text)
      return unless HTTP_SCHEMES.include?(uri.scheme.to_s.downcase) && uri.host

      uri
    rescue Addressable::URI::InvalidURIError
      nil
    end

    def self.normalize(value)
      parse(value)&.to_s
    end

    def self.token?(value)
      token = value.to_s
      token.match?(TOKEN_REGEXP) && parse(token)
    end
  end
end
