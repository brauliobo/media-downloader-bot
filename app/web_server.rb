require 'puma'

# Serves the Rails app (API and Vue frontend) from inside the bot process, which owns the Telegram session.
class WebServer
  def self.start(manager, port, host: ENV['FRONTEND_BIND'].presence || '127.0.0.1')
    raise ArgumentError, 'BOT_HTTP_TOKEN is required' if ENV['BOT_HTTP_TOKEN'].blank?
    raise ArgumentError, 'frontend must bind to loopback' unless Bot::Worker::HTTPService.loopback_host?(host)

    Rails.application.config.x.manager = manager
    server = Puma::Server.new(Rails.application, nil)
    server.add_tcp_listener(host, port)
    Thread.new do
      puts "Frontend started on #{host}:#{port}"
      server.run
    end
  end
end
