require 'time'
require 'json'
require 'fileutils'
require_relative 'safety'

module Utils
  module CookieJar
    module_function

    def parse_netscape(content)
      cookies = Hash.new { |hash, domain| hash[domain] = [] }
      content.each_line do |raw_line|
        line = raw_line.strip
        http_only = line.start_with?('#HttpOnly_')
        line = line.delete_prefix('#HttpOnly_') if http_only
        next if line.empty? || line.start_with?('#')

        domain, flag, path, secure, expiration, name, value = line.split(/\s+/, 7)
        domain = domain.to_s.delete_prefix('.').downcase
        next unless value && Safety.hostname?(domain)

        cookies[domain] << {
          'name'               => name,
          'value'              => value,
          'domain'             => domain,
          'include_subdomains' => flag.casecmp('TRUE').zero?,
          'path'               => path.start_with?('/') ? path : '/',
          'secure'             => secure.casecmp('TRUE').zero?,
          'expires'            => expiration.to_i,
          'http_only'          => http_only,
        }
      end
      cookies.transform_values { |entries| JSON.generate(entries) }
    end

    def write(session, dir)
      cookies = session&.reload&.cookies rescue session&.cookies
      return nil unless cookies.is_a?(Hash) && cookies.any?

      path = File.join(dir, 'cookies.in.txt')
      FileUtils.mkdir_p(dir)
      
      File.open(path, 'w') do |f|
        f.puts "# Netscape HTTP Cookie File"
        cookies.each do |domain, cookie_string|
          next if cookie_string.to_s.strip.empty?
          parse_entries(cookie_string).each do |name, value, attrs|
            write_line(f, domain, name, value, attrs)
          end
        end
      end
      
      File.size?(path) ? path : nil
    end

    def parse_entries(str)
      str = str.to_s.strip
      return [] if str.empty?
      if str.start_with?('[')
        return Array(JSON.parse(str)).filter_map do |cookie|
          next unless cookie.is_a?(Hash) && cookie['name']
          [cookie['name'], cookie['value'], cookie]
        end
      end
      
      str.split(/;\s*/).filter_map do |p| 
        n, v = p.split('=', 2)
        n.to_s.empty? ? nil : [n, v, {}]
      end
    end

    def write_line(f, domain, name, value, attrs)
      domain = Safety.netscape_field(attrs['domain'] || domain).downcase
      domain = domain.delete_prefix('.')
      return unless Safety.hostname?(domain)

      include_subdomains = attrs.fetch('include_subdomains', attrs.fetch('includeSubdomains', false))
      output_domain = include_subdomains ? ".#{domain}" : domain
      path = Safety.netscape_field(attrs.fetch('path', '/'))
      path = '/' unless path.start_with?('/')
      name = Safety.netscape_field(name)
      value = Safety.netscape_field(value)
      secure = attrs['secure'] ? 'TRUE' : 'FALSE'
      exp = attrs['expires'] || attrs['expirationDate'] || 0
      exp = Time.parse(exp).to_i if exp.is_a?(String)

      output_domain = "#HttpOnly_#{output_domain}" if attrs['http_only'] || attrs['httpOnly']
      f.puts "#{output_domain}\t#{include_subdomains ? 'TRUE' : 'FALSE'}\t#{path}\t#{secure}\t#{exp.to_i}\t#{name}\t#{value}"
    end
  end
end
