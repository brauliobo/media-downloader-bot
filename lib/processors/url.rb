require_relative 'media'
require_relative '../downloaders'

module Processors
  class Url < Media
    delegate :download, :download_one, to: :downloader

    def downloader
      @downloader ||= Downloaders.for(self)
    end

    def process
      result = download
      raise NotImplementedError, "process not implemented" unless result
      Array.wrap(result).each{ |r| r.processor = self }
      result
    ensure
      cleanup
    end

    def kindle_url?
      return false if url.to_s.empty?
      host = URI(url).host rescue nil
      Audiobook::Parsers::Kindle::READ_HOSTS.include?(host)
    end
  end
end


