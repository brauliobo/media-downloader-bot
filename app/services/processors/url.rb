module Processors
  class Url < Media
    delegate :download, :download_one, to: :downloader

    def downloader
      @downloader ||= Downloaders.for(self)
    end

    def process
      result = download
      Array.wrap(result).each{ |r| r.processor = self }
      result
    end
  end
end

