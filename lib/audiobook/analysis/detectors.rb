require_relative '../../audiobook'

module Audiobook
  module Analysis
    # Each detector names one way an assembled book reads wrong: a sentence that starts in the
    # middle, a heading that is really a paragraph, a page number left in the prose. They are
    # heuristics over the spoken text, so some of them also fire on writing that is merely
    # unusual; those are NOISY and are read as trends rather than as counts.
    module Detectors
      ROMAN    = /(?:ix|iv|v?i{1,3}|xi{0,3}|xiv|xv)/
      TERMINAL = /[.!?…:;]["”’)\]»]*\z/
      BULLETS  = /\A[•●○◦▪♦►▶■□➢✔✓✗➤★]|\A[o0°]\s\p{Lu}|\s[o0]\z/
      CATALOG  = /\A(?:p\. cm\.|I+\. T(?:i|í)tul|ISBN|isbn|CDD|CDU|\d+\.\d+\/\d+—dc)|\A\w+\d+\.\w\d+ \w\d+ \d{4}\z/

      # Read as: this sentence is wrong because…
      SENTENCE = {
        lower_start:    ->(text, _at) { text =~ /\A\p{Ll}/ },
        glued_words:    ->(text, _at) { text =~ /\p{L}{30,}/ },
        unfinished_mid: ->(text, at)  { !at.closes && text !~ TERMINAL },
        initial_split:  ->(text, _at) { text =~ /\s\p{Lu}\.\z/ },
        tiny:           ->(text, _at) { text.split.size <= 2 && text =~ /[.!?]\z/ && text !~ /\A\d/ },
        page_num_tail:  ->(text, _at) { text =~ /\p{L}[.,;]?\s\d{1,3}\z/ || text =~ /\p{Ll}[.,;]?\s#{ROMAN}\z/ },
        # "vi" is a roman numeral and also how Portuguese says "I saw", so it is left out.
        roman_inline:   ->(text, _at) { text =~ /\p{Ll}\s(?:ix|xi{1,3}|vi{2,3}|iv|i{2,3}|xiv|xv)\s\p{Ll}/ },
        # A call sits where the sentence it belongs to ends. Anywhere else the digits belong to
        # the word: MMS1, ClO2, a street number, an abbreviation.
        marker_tail:    ->(text, _at) { text =~ /\p{L}[.!?][”’")\]]?\d{1,2}(?=\s|\z)/ || text =~ /\p{L}\d{1,2}\z/ },
        # A note repeats its number bare; "1. " opens an item of a list, which is how most of a
        # book's numbered openings are written.
        footnote_lead:  ->(text, at)  { at.opens && text =~ /\A\d{1,3}\s+\p{L}/ },
        list_num_tail:  ->(text, _at) { text =~ /\s\d{1,2}[.)]\z/ || text =~ /\s\p{Lu}[.)]\z/ },
        # Leaders that survived; a spaced ellipsis in prose stays under the same bar as production.
        toc_leader:     ->(text, _at) { text =~ TextHelpers::TOC_LEADERS },
        dropcap:        ->(text, at)  { at.opens && at.prev_letter && text =~ /\A\p{Ll}/ },
        colon_end:      ->(text, at)  { at.closes && text =~ /:\z/ },
        hyphen_end:     ->(text, _at) { text =~ /-\z/ },
        # A straight quote opens as often as it closes; only an unambiguous closer is a split.
        quote_start:    ->(text, _at) { text =~ /\A[”’)\]»]/ },
        long_sentence:  ->(text, _at) { text.length > 600 },
        # A list entry ends without a stop and the next one opens lowercase; that is the list
        # working, not a paragraph torn in half.
        broken_para:    ->(text, at)  { at.closes && text !~ TERMINAL && at.next_lower && !TextHelpers.enumerated?(text) },
        caps_para:      ->(text, at)  { at.opens && at.closes && text.split.size <= 10 && text.scan(/\p{L}/).size > 3 && text == text.upcase },
        abbrev_end:     ->(text, at)  { at.closes && text =~ /(?:\A|[^\p{L}])(?:\p{Lu}|Dr|Dra|Sr|Sra|Prof|Mr|Mrs|St)\.\z/ },
        bullet_glyph:   ->(text, _at) { text =~ BULLETS },
        cip_line:       ->(text, _at) { text =~ CATALOG },
      }.freeze

      # Read as: this heading is not one.
      HEADING = {
        numeric_heading:  ->(text) { text =~ /\A[\d\s.,ivxlcIVXLC-]+\z/ },
        long_heading:     ->(text) { text.split.size > 12 },
        sentence_heading: ->(text) { text =~ /[.!?]\z/ && text.split.size > 5 && text != text.upcase },
        lower_heading:    ->(text) { text =~ /\A\p{Ll}/ },
        letter_heading:   ->(text) { text =~ /\A\p{Lu}\z/ },
      }.freeze

      # These say how a book is written, not that it was assembled wrongly. A bulleted item reads
      # as its own short paragraph, a lead-in keeps its colon, a citation ends in a number, and a
      # line of verse ends without a stop before a lowercase line. Sampled against the corpus,
      # one hit in ten is a defect, so they are read as trends and are reported apart from the
      # counts that are meant to reach zero.
      SHAPE = %i[lower_start colon_end footnote_lead caps_para marker_tail tiny
                 list_num_tail page_num_tail broken_para].freeze

      def self.names = SENTENCE.keys + HEADING.keys

      # Every spoken sentence with what a detector needs to know about its neighbours.
      def self.spoken(book)
        items = book.pages.flat_map { |page| page.items.map { |item| [page.number, item] } }
        items.each_with_index.flat_map do |(page, item), idx|
          next [] unless narrated?(item)

          context = neighbours(items, idx)
          item.sentences.each_with_index.map do |sentence, at|
            # `first`/`last` would resolve to Hash methods on the SymMash rather than to these.
            [sentence, context.merge(page: page, opens: at.zero?, closes: at == item.sentences.size - 1)]
          end
        end
      end

      def self.hits(book, spoken = spoken(book))
        found = Hash.new { |hash, name| hash[name] = [] }
        spoken.each do |sentence, at|
          SENTENCE.each { |name, test| found[name] << [at.page, sentence.text] if test.call(sentence.text, at) }
        end
        headings(book, found)
      end

      def self.headings(book, found)
        book.pages.each do |page|
          page.items.grep(Heading).each do |heading|
            HEADING.each { |name, test| found[name] << [page.number, heading.text] if test.call(heading.text) }
          end
        end
        found
      end

      def self.narrated?(item) = item.is_a?(Paragraph) && !item.is_a?(Reference)

      def self.neighbours(items, idx)
        following = items[idx + 1]&.last
        preceding = idx.positive? ? items[idx - 1].last : nil
        SymMash.new(
          next_lower:  following.is_a?(Paragraph) && following.sentences.first&.text.to_s.match?(/\A\p{Ll}/),
          prev_letter: preceding.is_a?(Heading) && preceding.text.match?(/\A\p{Lu}\z/)
        )
      end
    end
  end
end
