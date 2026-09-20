require 'set'
require_relative '../text_helpers'

module Audiobook
  # What each page of a book is for. FontRoles reads a book's type; this reads its pages. A
  # contents list, an index and a cataloguing record each name themselves differently, and every
  # rule that drops a page or looks for where the body ends asks here rather than deciding again.
  class PageRoles
    def self.from_lines(lines_data) = new(lines_data)

    attr_reader :contents, :index, :rights

    def initialize(lines_data)
      pages     = lines_data.map { |line| SymMash.wrap(line) }.group_by(&:page)
      @contents = contents_pages(pages)
      @index    = index_pages(pages)
      @rights   = rights_pages(pages)
    end

    private

    # ---------- cataloguing record ----------

    RIGHTS_PAGES = 8
    CATALOG_MARK = /\bis[bs]n\b|\bcd[du]\b|\bp\. cm\.|\bdc\d\d\b|catalogaç|cataloging/i
    # The opening or closing pages carry a cataloguing record: the notice, the identifiers and
    # the shelf codes. The same page may still hold a dedication or an acknowledgement, so the
    # page is named here and the record's own lines are picked out where it is dropped.
    def rights_pages(pages)
      record_pages(pages.keys.sort).select { |page| catalog_page?(pages[page]) }.to_set
    end

    # A book prints its record at the front or at the back, never in the middle.
    def record_pages(pages) = pages.first(RIGHTS_PAGES) | pages.last(RIGHTS_PAGES)

    def catalog_page?(page_lines) = page_lines.map { |line| line.text.to_s }.join(' ').match?(CATALOG_MARK)

    # ---------- contents pages ----------

    CONTENTS_TITLE = /\A(?:contents|table\s+of\s+contents|conte(?:ú|u)dos?|sum(?:á|a)rio|(?:í|i)ndice|contenido|
                          tabela?\s+de\s+conte(?:ú|u)dos?|inhalt)\b/xi
    CHAPTER_LABEL  = /\A(?:cap(?:í|i)tulo|chapter|parte|part|se(?:c|ç)(?:ç|c)?(?:ã|a)o|anexo|ap(?:ê|e)ndice|appendix)
                       \s*(?:\d|[ivxlc]+\b)/xi
    CONTENTS_ENTRIES = 5
    LISTED_ENTRIES   = 3
    # A page announces the contents with a title, not with a sentence that opens on the word.
    TITLE_WORDS      = 3
    ENTRY_WORDS      = 12
    ENTRY_SHARE      = 0.8

    # A contents page lists what is elsewhere: leader lines, chapter labels and the pages they
    # point at. Reading it aloud tells the listener nothing, and the pages that carry the list
    # on look the same once its heading is behind them.
    def contents_pages(pages)
      leaderless = Set.new
      pages.keys.sort.each_with_object(Set.new) do |page, found|
        texts = pages[page].map { |line| line.text.to_s.strip }.reject(&:empty?)
        next if texts.size < LISTED_ENTRIES

        named = texts.first(3).any? { |text| contents_title?(text) }
        next found << page if folio_list?(texts, opened: named || found.include?(page - 1))
        # A list with nothing to recognise it by but its entries carries on the same way, or the
        # chapter that follows an ordinary contents page would be read as more of the list.
        next unless (named || leaderless.include?(page - 1)) && leaderless_list?(texts)

        leaderless << page
        found << page
      end
    end

    # The list names itself entry by entry: leaders, a chapter label, or the page each points at.
    def folio_list?(texts, opened:)
      entries = texts.count { |text| contents_entry?(text) }
      return true if entries >= CONTENTS_ENTRIES

      opened && entries + texts.count { |text| text.match?(/\S\s\d{1,4}\z/) } >= LISTED_ENTRIES
    end

    # A book converted from an ebook prints no page number beside an entry, so the entries are
    # the only evidence: such a page is almost nothing but short lines that name something
    # instead of saying it, where body text wraps and only looks like them in places.
    def leaderless_list?(texts)
      listing = texts.count { |text| entry_line?(text) }
      listing >= CONTENTS_ENTRIES && listing >= texts.size * ENTRY_SHARE
    end

    def contents_entry?(text) = TextHelpers.toc_entry?(text) || text.match?(CHAPTER_LABEL)
    def contents_title?(text) = text.match?(CONTENTS_TITLE) && text.split.size <= TITLE_WORDS
    def entry_line?(text) = text.split.size.between?(1, ENTRY_WORDS) && !TextHelpers.ends_with_punctuation?(text)

    # ---------- index and reference lists ----------

    INDEX_ENTRIES = 8
    # An entry names the pages it appears on: "Bactérias 28, 41, 53, 60".
    FOLIO_LIST    = /,\s*\d{1,4}(?:\s*[–—-]\s*\d{1,4})?(?:\s*,\s*\d{1,4}(?:\s*[–—-]\s*\d{1,4})?)*\z/
    FOLIO_SHARE   = 0.3
    SORTED_SHARE  = 0.8
    SORTED_PAGES  = 3
    SORT_KEY      = 12

    # An index is a lookup table: entries in alphabetical order, each naming a page rather than
    # saying anything. Read aloud it is minutes of names and numbers.
    def index_pages(pages)
      entries = pages.to_h { |page, page_lines| [page, entry_texts(page_lines)] }
        .select { |_, texts| texts.size >= INDEX_ENTRIES }
      folios  = entries.select { |_, texts| folio_entries?(texts) }.keys
      sorted  = entries.select { |_, texts| sorted_entries?(texts) }.keys
      (close_gaps(folios) + runs(close_gaps(sorted))).to_set
    end

    def entry_texts(page_lines)
      page_lines.map { |line| line.text.to_s.strip }.reject { |text| text.scan(/\p{L}/).size < 3 }
    end

    def folio_entries?(texts) = texts.count { |text| text.match?(FOLIO_LIST) } >= texts.size * FOLIO_SHARE

    def sorted_entries?(texts)
      keys = texts.filter_map { |text| text.downcase.sub(/\A[^\p{L}]+/, '')[0, SORT_KEY].presence }
      keys.size > 1 && keys.each_cons(2).count { |above, below| above <= below } >= (keys.size - 1) * SORTED_SHARE
    end

    # A page between two index pages is one, whatever its own entries look like.
    def close_gaps(pages) = (pages + pages.select { |page| pages.include?(page + 2) }.map(&:succ)).sort

    # A chapter that lists something in order is not an index: ordering only names one when it
    # is the point of several pages running.
    def runs(pages) = pages.slice_when { |prev, page| page > prev + 1 }.select { |run| run.size >= SORTED_PAGES }.flatten
  end
end
