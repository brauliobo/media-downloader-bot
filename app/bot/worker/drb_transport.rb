require 'drb/drb'

module Bot
  module Worker
    # Calls the bot service object itself, which answers with the values as they are.
    class DRbTransport
      def initialize(uri, remote: DRbObject.new_with_uri(uri)) = @remote = remote

      def call(method, result: nil, **kwargs) = @remote.public_send(method, **kwargs)
    end
  end
end
