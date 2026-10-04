module Audiobook
  module Analysis
    # What the book says that the narration does not. Every other detector counts something
    # wrongly spoken; this one counts prose wrongly silent, so a filter that swallows a chapter
    # moves a number instead of passing unnoticed. Contents pages and running heads are counted
    # here too, on purpose: what a drop rule is worth is read from how this moves, not from its
    # total.
    module Coverage
      MIN_WORDS = 5

      def self.unspoken(book, spoken) = silent(book, spoken) { |text| probe(text) }
      def self.short(book, spoken)    = silent(book, spoken) { |text| brief(text) }

      # A page whose content is a dominant image reaches no text layer at all, so nothing about
      # it can be counted as lost; it is counted as unread instead.
      def self.imaged(book) = Array(book.data&.content&.images).map { |image| image[:page] }

      def self.words_of(text) = text.to_s.downcase.scan(/\p{L}{2,}/).join(' ')

      # Assembly breaks a hyphenated word back together and drops a marker, so neither end of a
      # source line is evidence either way; what stands between them is. A URL is asked for by
      # the host the narration says, not by the address the page printed.
      def self.probe(text)
        words = words_of(TextHelpers.spoken_urls(text)).split
        words[1..-2].join(' ') if words.size >= MIN_WORDS + 2
      end

      # A heading, an index entry, a caption and a table cell have no middle to ask about, so
      # they are asked about whole and counted apart: a page of them says something different
      # from a page of lost prose.
      def self.brief(text)
        words = words_of(TextHelpers.spoken_urls(text)).split
        words.join(' ') if words.size.between?(2, MIN_WORDS + 1)
      end

      # A heading is narrated like anything else, so its text is not lost when it is a heading.
      def self.headings(book) = book.pages.flat_map { |page| page.items.grep(Heading).map(&:text) }

      def self.silent(book, spoken, &probe)
        said = words_of((spoken.map { |sentence, _| sentence.text } + headings(book)).join(' '))
        Array(book.data&.content&.lines).filter_map do |line|
          asked = probe.call(line.text)
          [line.page, line.text.to_s.strip] if asked && !said.include?(asked)
        end
      end
    end
  end
end
