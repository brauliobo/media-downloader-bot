require 'uri'
require_relative 'puppeteer_base'

module Audiobook
  module Parsers
    class Kindle < PuppeteerBase

      READ_HOSTS = [
        'read.amazon.com',
        'ler.amazon.com.br'
      ].freeze

      def self.supports?(url)
        host = URI(url).host rescue nil
        READ_HOSTS.include?(host)
      end

      # Expect opts to contain :session_uid to fetch cookies from DB. If cookies for the domain
      # are missing, raise an error as requested.
      def self.extract_data(target_url, stl: nil, opts: nil, **_kwargs)
        raise ArgumentError, 'TARGET_URL must be a Kindle reader URL' unless supports?(target_url)
        raise 'Authentication redirect detected (signin). Ensure cookies are set.' if target_url.to_s.include?('signin')
        domain = URI(target_url).host
        parent = parent_host_for(domain)
        primary_header = fetch_cookie_header_for(domain)
        parent_header  = fetch_cookie_header_for(parent) rescue nil
        primary = parse_cookies(primary_header, domain)
        parentc = parent_header.to_s.strip.empty? ? primary.map { |c| c.merge(domain: parent) } : parse_cookies(parent_header, parent)
        cookies = primary + parentc
        super(target_url, stl: stl, opts: SymMash.new(opts.to_h.merge(cookies: cookies)))
      end

      def self.fetch_cookie_header_for(domain)
        session_uid = ENV['SESSION_UID']
        session_uid = session_uid.to_i if session_uid.is_a?(String) && session_uid =~ /\A\d+\z/
        cookie_header = nil
        if session_uid
          s = Models::Session.find uid: session_uid
          cookie_header = s&.cookies&.[](domain)
        end
        if cookie_header.to_s.strip.empty?
          raise "Missing session cookie for #{domain}. Please set it with /cookie #{domain} <cookie>"
        end
        cookie_header
      end

      def self.parse_cookies(cookie_header, domain)
        return [] if cookie_header.to_s.strip.empty?
        if cookie_header.strip.start_with?('[')
          JSON.parse(cookie_header) rescue []
        else
          cookie_header.split(/;\s*/).filter_map do |pair|
            name, value = pair.split('=', 2)
            next if name.to_s.empty?
            { name: name, value: value.to_s, domain: domain, path: '/' }
          end
        end
      end

      def self.parent_host_for(host)
        segs = host.to_s.split('.')
        return host if segs.size < 2
        segs[-2..-1].join('.')
      end
    end
  end
end


