require 'time'
require 'json'
require 'fileutils'

module Utils
  module CookieJar
    def self.write(session, dir)
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

    def self.parse_entries(str)
      str = str.to_s.strip
      return [] if str.empty?
      return JSON.parse(str).map { |c| [c['name'], c['value'], c] } if str.start_with?('[')
      
      str.split(/;\s*/).filter_map do |p| 
        n, v = p.split('=', 2)
        n.to_s.empty? ? nil : [n, v, {}]
      end
    end

    def self.write_line(f, domain, name, value, attrs)
      domain = ".#{domain}" unless domain.start_with?('.')
      path = attrs.fetch('path', '/')
      secure = attrs['secure'] ? 'TRUE' : 'FALSE'
      exp = attrs['expires'] || attrs['expirationDate'] || 0
      exp = Time.parse(exp).to_i if exp.is_a?(String)
      
      f.puts "#{domain}\tTRUE\t#{path}\t#{secure}\t#{exp.to_i}\t#{name}\t#{value}"
    end
  end
end

