require 'faraday'

module Bot
  module Worker
    class HTTPClient
      Error = Class.new RuntimeError
      # A call that sends a book waits for the upload (the bot waits up to 1800 s for it): Faraday's 60 s timed the call out after the book was posted.
      TIMEOUT = 2_000

      def initialize(uri, **request)
        headers = {'Authorization' => "Bearer #{ENV.fetch('BOT_HTTP_TOKEN')}"}
        @conn   = Faraday.new(url: uri, headers: headers, request: {timeout: TIMEOUT}.merge(request)) do |f|
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
