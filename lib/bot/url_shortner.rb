class Manager
  class UrlShortner

    SITES = SymMash.new(
      Youtube: -> info do
        "youtu.be/#{info.display_id}"
      end
    )

    def self.shortify info
      url = info.url.dup
      url.gsub! /^https?:\/\//, ''
      url.gsub! /^www\./, ''

      return url unless site = SITES[info.extractor_key]

      url = site.call info
      url
    end

  end
end
