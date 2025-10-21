module Utils
  class UrlShortener

    SITES = SymMash.new(
      Youtube: -> info { "youtu.be/#{info.display_id}" }
    )

    def self.shortify(info)
      url = info.url.dup
      url.gsub! /^https?:\/\//, ''
      url.gsub! /^www\./, ''
      return url unless site = SITES[info.extractor_key]
      site.call(info)
    end
  end
end


