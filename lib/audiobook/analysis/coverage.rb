require_relative '../../audiobook'

module Audiobook
  module Analysis
    # What the book says that the narration does not. Every other detector counts something
    # wrongly spoken; this one counts prose wrongly silent, so a filter that swallows a chapter
    # moves a number instead of passing unnoticed. Contents pages and running heads are counted
    # here too, on purpose: what a drop rule is worth is read from how this moves, not from its
    # total.
    module Coverage
      MIN_WORDS = 5

      def self.unspoken(book, spoken)
        said = words_of(spoken.map { |sentence, _| sentence.text }.join(' '))
        source_lines(book).reject { |_, _, probe| said.include?(probe) }
          .map { |page, text, _| [page, text] }
      end

      def self.source_lines(book)
        Array(book.data&.content&.lines).filter_map do |line|
          probe = probe(line.text)
          [line.page, line.text.to_s.strip, probe] if probe
        end
      end

      def self.words_of(text) = text.to_s.downcase.scan(/\p{L}{2,}/).join(' ')

      # Assembly breaks a hyphenated word back together and drops a marker, so neither end of a
      # source line is evidence either way; what stands between them is.
      def self.probe(text)
        words = words_of(text).split
        words[1..-2].join(' ') if words.size >= MIN_WORDS + 2
      end
    end
  end
end
