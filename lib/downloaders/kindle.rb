require_relative 'base'

module Downloaders
  class Kindle < Base

    Downloaders.register(self)

    def self.supports?(ctx)
      return false if ctx.url.to_s.empty?
      host = URI(ctx.url).host rescue nil
      Audiobook::Parsers::Kindle::READ_HOSTS.include?(host)
    end
    def download
      asin = begin Addressable::URI.parse(url).query_values&.[]("asin") rescue nil end
      info = SymMash.new(title: url, _filename: 'kindle', display_id: asin || url)
      [SymMash.new(line: url, url: url, opts: opts, info: info)]
    end

    def download_one(i, pos: nil)
      (stl || st)&.update 'OCR & TTS (Kindle)'
      i.uploads = Audiobook.generate_uploads(url, dir: dir, stl: (stl || st), opts: opts)
      true
    rescue => e
      (stl || st)&.error "Kindle processing failed", exception: e
      false
    end

  end
end
