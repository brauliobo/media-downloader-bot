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
    end
  end
end


