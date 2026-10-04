require 'set'

module Audiobook
  # A file made by converting one format into another sometimes reprints a passage it has already
  # printed, a line or a page further on. The page says it once; read out, the book says it twice
  # and the listener hears a skip in the record. What is compared is the letters alone, because
  # the two printings break their lines differently and one of them glues a word to the next.
  module Repeats
    MIN_WORDS = 12

    def self.strip(items)
      said = Set.new
      items.each do |entry|
        next unless entry.item.is_a?(Paragraph)

        entry.item.sentences.reject! { |sentence| repeat?(said, sentence.text) }
      end
      items.reject { |entry| entry.item.is_a?(Paragraph) && entry.item.sentences.empty? }
    end

    def self.repeat?(said, text)
      return false if text.to_s.split.size < MIN_WORDS

      !said.add?(text.downcase.scan(/\p{L}|\p{N}/).join)
    end
  end
end
