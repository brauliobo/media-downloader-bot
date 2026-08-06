require_relative 'base'

module Downloaders
  class Kindle < Base

    Downloaders.register(self)

    def self.supports?(ctx)
      return false if ctx.url.to_s.empty?
      host = Utils::Url.parse(ctx.url)&.host
      Audiobook::Parsers::Kindle::READ_HOSTS.include?(host)
    end
    def download
      source_url = normalized_url
      asin = Utils::Url.parse(source_url)&.query_values&.[]('asin')
      info = SymMash.new(title: source_url, _filename: 'kindle', display_id: asin || source_url)
      [SymMash.new(line: source_url, url: source_url, opts: opts, info: info)]
    end

    def download_one(i, pos: nil)
      (stl || st)&.update 'OCR & TTS (Kindle)'
      i.uploads = Audiobook.generate_uploads(normalized_url, dir: dir, stl: (stl || st), opts: opts)
      true
    rescue => e
      (stl || st)&.error "Kindle processing failed", exception: e
      false
    end

  end
end
