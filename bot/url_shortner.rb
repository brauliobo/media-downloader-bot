class Bot
  class UrlShortner

    SITES = SymMash.new(
      Youtube: -> info do
        "youtu.be/#{info.display_id}"
      end
    )

    def self.shortify info
      return unless site = SITES[info.extractor_key]
      site.call info
    end

  end
end
