require 'drb/drb'
require 'uri'

module Bot
  module Worker
    class DRbService
      def self.start(service, uri)
        u = URI.parse(uri)
        begin
          DRb.start_service(u.to_s, service)
          puts "Worker DRb service started at #{u}"
          service
        rescue Errno::EADDRINUSE
          puts "Port #{u.port} in use, trying #{u.port + 1}..."
          u.port += 1
          retry
        end
      end
    end
  end
end
