require 'mechanize'

module Utils
  class HTTP

    def self.client
      Thread.current[:utils_http] ||= Mechanize.new.tap do |a|
        t = ENV['HTTP_TIMEOUT']&.to_i || 30.minutes
        a.open_timeout = t
        a.read_timeout = t
      end
    end

    delegate_missing_to :client

  end
end

