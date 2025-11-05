require 'drb/drb'

module Bot
  module Worker
    class DRbService
      def self.start(service, uri)
        DRb.start_service(uri, service)
        puts "Worker DRb service started at #{uri}"
        service
      end
    end
  end
end

