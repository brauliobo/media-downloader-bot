require 'fileutils'
require 'ipaddr'
require 'mechanize'
require 'net/http'
require 'uri'

module Utils
  class HTTP
    PUBLIC_MAX_BYTES = ENV.fetch('PUBLIC_HTTP_MAX_BYTES', 5 * 1024 * 1024).to_i
    PUBLIC_DOWNLOAD_MAX_BYTES = ENV.fetch('PUBLIC_HTTP_DOWNLOAD_MAX_BYTES', 2 * 1024 * 1024 * 1024).to_i
    PUBLIC_REDIRECTS = ENV.fetch('PUBLIC_HTTP_MAX_REDIRECTS', 3).to_i
    PUBLIC_USER_AGENT = 'media-downloader-bot'.freeze

    class << self

      def client(timeout: ENV['HTTP_TIMEOUT']&.to_i || 30.minutes)
        agent = Thread.current[:utils_http] ||= Mechanize.new { |shared|
          shared.keep_alive = false
          shared.idle_timeout = 0
        }
        agent.keep_alive = false
        agent.idle_timeout = 0
        agent.open_timeout = timeout
        agent.read_timeout = timeout
        agent.write_timeout = timeout
        agent
      end

      def reset!
        agent = Thread.current[:utils_http]
        Thread.current[:utils_http] = nil
        agent&.shutdown
      end

      delegate_missing_to :client

      def post(...) = request(:post, ...)
      def get(...)  = request(:get, ...)

      # A service base URL, however it was written, with the path of one of its endpoints.
      def url(base, path = '') = "#{base.to_s.delete_suffix('/')}#{path}"

      def request(verb, ...) = Retry.http { (Thread.current[:utils_http] || client).public_send(verb, ...) }
      private :request

      # Every service backend refuses the same way; only the label differs.
      def assert_ok!(response, label)
        raise "#{label} failed: #{response.code}" unless response.code.to_i == 200

        response
      end

      def get_public(value, max_bytes: PUBLIC_MAX_BYTES, redirects: PUBLIC_REDIRECTS)
        body = +''
        request_public(value, max_bytes: max_bytes, redirects: redirects) do |chunk, _res|
          body << chunk
        end
        body
      end

      def download_public(value, path, max_bytes: PUBLIC_DOWNLOAD_MAX_BYTES, redirects: PUBLIC_REDIRECTS)
        part = "#{path}.part"
        FileUtils.mkdir_p(File.dirname(path))
        type = nil
        File.open(part, 'wb') do |file|
          type = request_public(value, max_bytes: max_bytes, redirects: redirects, read_timeout: 600) do |chunk, _res|
            file.write(chunk)
          end
        end
        File.rename(part, path)
        type
      ensure
        File.unlink(part) if part && File.exist?(part)
      end

      private

      def request_public(value, max_bytes:, redirects:, read_timeout: 30, &block)
        uri       = URI.parse(value.to_s)
        addresses = Safety.public_addresses(uri.host)
        raise ArgumentError, 'URL must resolve only to public addresses' unless uri.is_a?(URI::HTTP) && addresses.any? && !uri.userinfo

        last_error = nil
        public_ips(addresses).each do |ip|
          begin
            return fetch_public(uri, ip, max_bytes: max_bytes, redirects: redirects, read_timeout: read_timeout, &block)
          rescue Net::OpenTimeout, Errno::EHOSTUNREACH, Errno::ECONNREFUSED, Errno::ENETUNREACH, SocketError => e
            last_error = e
          end
        end
        raise last_error
      end

      def public_ips(addresses)
        addresses.sort_by { |addr| IPAddr.new(addr).ipv4? ? 0 : 1 }
      end

      def fetch_public(uri, ip, max_bytes:, redirects:, read_timeout:, &block)
        http              = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr       = ip
        http.use_ssl      = uri.scheme == 'https'
        http.open_timeout = 10
        http.read_timeout = read_timeout

        content_type = nil
        http.request(Net::HTTP::Get.new(uri.request_uri, {'User-Agent' => PUBLIC_USER_AGENT})) do |res|
          if res.is_a?(Net::HTTPRedirection)
            raise ArgumentError, 'too many HTTP redirects' unless redirects.positive?
            location = URI.join(uri, res.fetch('location')).to_s
            return request_public(location, max_bytes: max_bytes, redirects: redirects - 1, read_timeout: read_timeout, &block)
          end

          raise "HTTP request failed: #{res.code}" unless res.is_a?(Net::HTTPSuccess)
          length = res['content-length']&.to_i
          raise ArgumentError, 'HTTP response is too large' if length && length > max_bytes

          content_type = res['content-type']
          downloaded = 0
          res.read_body do |chunk|
            downloaded += chunk.bytesize
            raise ArgumentError, 'HTTP response is too large' if downloaded > max_bytes
            yield chunk, res
          end
        end

        content_type
      end

    end

  end
end
