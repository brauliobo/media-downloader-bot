module Audiobook
  # Table-of-contents leaders and the page number they point at are noise when spoken.
  module Contents
    # Leaders run long; a spaced ellipsis in prose stays under six dots.
    LEADERS = /(?:\.\s*){6,}|(?:…\s*){3,}/

    module_function

    def entry?(text) = text.to_s.match?(LEADERS)

    def strip_leaders(text)
      return text unless entry?(text)

      text.gsub(LEADERS, ' ').gsub(Markers::TAG, '').sub(/\s+\d{1,4}\s*\z/, '').gsub(/\s+/, ' ').strip
    end
  end
end
