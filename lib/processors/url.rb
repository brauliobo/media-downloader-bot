require_relative 'base'
require_relative '../downloaders'

module Processors
  class Url < Base
    delegate :download, :download_one, to: :downloader

    def downloader
      @downloader ||= Downloaders.for(self)
    end

    def kindle_url?
      return false if url.to_s.empty?
      host = URI(url).host rescue nil
      Audiobook::Parsers::Kindle::READ_HOSTS.include?(host)
    end
  end
end


