require 'faraday'

module Bot
  module Worker
    class HTTPClient
      Error = Class.new RuntimeError

      def initialize(uri, **request)
        headers = {'Authorization' => "Bearer #{ENV.fetch('BOT_HTTP_TOKEN')}"}
        @conn   = Faraday.new(url: uri, headers: headers, request: request) do |f|
          f.request :json
          f.response :json
        end
      end

      def get(path, params = nil) = request(:get, path, params)
      def post(path, params = nil) = request(:post, path, params)

      private

      def request(verb, path, params)
        response = @conn.public_send(verb, "/#{path}", params)
        raise Error, "bot HTTP service /#{path} returned #{response.status}: #{response.body['error']}" unless response.success?

        response.body
      end
    end
  end
end
