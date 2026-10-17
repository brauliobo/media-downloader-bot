module Bot
  module Worker
    # Posts to the bot service, where messages and files travel as JSON and the body names the value by `result`.
    class HTTPTransport
      def initialize(uri) = @client = HTTPClient.new(uri)

      def call(method, result: nil, **payload)
        payload[:msg] = payload[:msg].to_h if payload[:msg]
        if (info = payload[:file_id_or_info])
          remote = FileId.remote(info)
          payload[:remote_id] = remote if remote
          payload[:file_id_or_info] = FileId.call(info)
        end
        body = @client.post(method, payload)
        body = SymMash.new(body) if body.is_a?(Hash)
        result ? body[result] : body
      end
    end
  end
end
