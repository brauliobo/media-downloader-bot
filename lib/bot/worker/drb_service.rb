require 'drb/drb'
require 'drb/acl'
require 'uri'

module Bot
  module Worker
    class DRbService
      def self.start(service, uri)
        u = URI.parse(uri)
        acl = ACL.new(%w[deny all allow 127.0.0.1 allow ::1])
        begin
          DRb.start_service(u.to_s, service, tcp_acl: acl)
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
