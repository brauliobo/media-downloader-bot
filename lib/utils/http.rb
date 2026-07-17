require 'mechanize'
require 'net/http'
require 'uri'
require_relative 'safety'

module Utils
  class HTTP
    PUBLIC_MAX_BYTES = ENV.fetch('PUBLIC_HTTP_MAX_BYTES', 5 * 1024 * 1024).to_i
    PUBLIC_REDIRECTS = ENV.fetch('PUBLIC_HTTP_MAX_REDIRECTS', 3).to_i

    class << self

      def client
        Thread.current[:utils_http] ||= Mechanize.new.tap do |a|
          t = ENV['HTTP_TIMEOUT']&.to_i || 30.minutes
          a.open_timeout = t
          a.read_timeout = t
        end
      end

      delegate_missing_to :client

      def get_public(value, max_bytes: PUBLIC_MAX_BYTES, redirects: PUBLIC_REDIRECTS)
        uri       = URI.parse(value.to_s)
        addresses = Safety.public_addresses(uri.host)
        raise ArgumentError, 'URL must resolve only to public addresses' unless uri.is_a?(URI::HTTP) && addresses.any? && !uri.userinfo

        http              = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr       = addresses.first
        http.use_ssl      = uri.scheme == 'https'
        http.open_timeout = 10
        http.read_timeout = 30

        body = +''
        http.request(Net::HTTP::Get.new(uri.request_uri, {'User-Agent' => 'media-downloader-bot'})) do |res|
          if res.is_a?(Net::HTTPRedirection)
            raise ArgumentError, 'too many HTTP redirects' unless redirects.positive?
            location = URI.join(uri, res.fetch('location')).to_s
            return get_public(location, max_bytes: max_bytes, redirects: redirects - 1)
          end

          raise "HTTP request failed: #{res.code}" unless res.is_a?(Net::HTTPSuccess)
          length = res['content-length']&.to_i
          raise ArgumentError, 'HTTP response is too large' if length && length > max_bytes

          res.read_body do |chunk|
            raise ArgumentError, 'HTTP response is too large' if body.bytesize + chunk.bytesize > max_bytes
            body << chunk
          end
        end

        body
      end

    end

  end
end
