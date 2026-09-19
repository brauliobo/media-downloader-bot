require 'set'
require_relative '../text_helpers'
require_relative 'font_roles'

module Audiobook
  # Decides which extracted lines belong to the narration. Page furniture, the cataloguing
  # record and the contents pages are all printed for a reader who can see the page, and say
  # nothing to a listener.
  class PageFilter
    FILTERS = %i[tables furniture rights_record contents index skipped_pages].freeze

    def self.narrated(lines_data, selected_pages: nil, skip_pages: nil)
      new(lines_data, selected_pages: selected_pages, skip_pages: skip_pages).narrated
    end

    def initialize(lines_data, selected_pages: nil, skip_pages: nil)
      @lines_data = lines_data
      @selected_pages = selected_pages
      @skip_pages = skip_pages
    end

    def narrated
      FILTERS.reduce(@lines_data) { |lines, filter| send(:"without_#{filter}", lines) }
    end

    private

    def wrap(lines_data) = lines_data.map { |line| SymMash.wrap(line) }

    def reject_lines(lines_data, lines, &drop)
      kept = lines_data.select.with_index { |_, idx| !drop.call(lines[idx]) }
      kept.size == lines_data.size ? lines_data : kept
    end

    # ---------- tables ----------

    # A table is drawn for the eye. Read out cell by cell it is a list of names and numbers with
    # nothing holding them together, and the columns of a row arrive interleaved with each other.
    def without_tables(lines_data)
      reject_lines(lines_data, wrap(lines_data)) { |line| line.table }
    end

    # ---------- page furniture ----------

    FOLIO           = /\A[ivxlcdm\d]{1,7}[.\]]?\z/i
    FURNITURE_WORDS = 8
    OUTLIER_MARGIN  = 0.1
    MARGIN_BAND     = 0.15
    MARGINALIA_SIZE = 0.55
    EDGE_RUN        = 4
    TITLE_SIZE      = 1.25

    # Page furniture is a folio, a running head repeated across pages, or a short line parked
    # away from the text block. None of it belongs in the narration.
    def without_furniture(lines_data)
      return lines_data if lines_data.empty?

      lines = wrap(lines_data)
      pages = lines.group_by(&:page)
      return lines_data if @selected_pages && pages.size < 3

      furniture = furniture_lines(pages, lines).map(&:object_id).to_set
      reject_lines(lines_data, lines) { |line| furniture.include?(line.object_id) }
    end

    def furniture_lines(pages, lines)
      metrics = body_metrics(lines)
      counts  = repeat_counts(pages)
      limit   = repeat_limit(pages.size)
      edges   = pages.values.map { |page_lines| edge_lines(page_lines) }
      # A re-rendered PDF reflows folios and running heads into the text, so the two patterns
      # that name themselves are also looked for in the page bands and outside the column.
      parked  = edges.zip(pages.values).map do |edge, page_lines|
        edge | margin_band(page_lines) | off_column_lines(page_lines, metrics) |
          repeated_run(page_lines, counts, limit)
      end
      folios = parked.flatten.select { |line| folio?(line, pages[line.page]) }
      (folios + repeated_margins(parked, folios, counts, limit, metrics) +
        column_outliers(edges, folios, metrics, lines) + marginalia(lines, metrics)).to_set
    end

    def short_line?(line) = line.text.to_s.split.size <= FURNITURE_WORDS

    # The outermost lines of a page are where a header or footer lands when nothing else moved it.
    def edge_lines(page_lines) = page_lines.values_at(0, 1, -2, -1).compact.uniq.select { |line| short_line?(line) }

    # How often each line is printed, counted once per page so a refrain within one page is not
    # mistaken for a line the book repeats.
    def repeat_counts(pages)
      pages.values.flat_map { |page_lines| page_lines.map { |line| TextHelpers.comparable_key(line.text) }.uniq }.tally
    end

    def repeat_limit(page_count) = [[(page_count * 0.3).ceil, 3].min, 2].max

    # A running head or foot is as many lines as keep repeating from the page edge inward: a
    # footer set on three lines is one piece of furniture, not two lines of it and one of prose.
    # Width says nothing here, so a long footer is caught where the geometry tests above miss it.
    def repeated_run(page_lines, counts, limit)
      repeats = ->(line) { counts[TextHelpers.comparable_key(line.text)] >= limit }
      head = page_lines.take_while(&repeats).first(EDGE_RUN)
      tail = page_lines.reverse.take_while(&repeats).first(EDGE_RUN)
      (head + tail).uniq
    end

    def margin_band(page_lines)
      page_lines.select do |line|
        height = line.page_height.to_f
        next false unless height.positive? && short_line?(line)

        line.y_min.to_f <= height * MARGIN_BAND || line.y_max.to_f >= height * (1 - MARGIN_BAND)
      end
    end

    def off_column_lines(page_lines, metrics)
      return [] unless metrics

      page_lines.select { |line| short_line?(line) && off_column?(line, metrics) }
    end

    # A page carries one folio; a column of bare numbers in the same size is a note marker list.
    def folio?(line, page_lines)
      return false unless line.text.to_s.strip.match?(FOLIO)

      size = FontRoles.quantize(line.font_size)
      page_lines.count { |other| FontRoles.quantize(other.font_size) == size && TextHelpers.marker_line?(other.text) } < 2
    end

    # A running head repeats across pages; a chapter title that quotes it is set larger.
    def repeated_margins(margins, folios, counts, limit, metrics)
      (margins.flatten - folios).select do |line|
        counts[TextHelpers.comparable_key(line.text)] >= limit && !title_size?(line, metrics)
      end
    end

    # A running head or watermark sits at the page edge outside the column the body keeps to,
    # and stands alone there: an indented line of verse shares its margin with its block.
    def column_outliers(edges, folios, metrics, lines)
      return [] unless metrics

      shared = self.class.shared_left_edges(lines)
      (edges.flatten - folios).select do |line|
        FontRoles.quantize(line.font_size).to_f <= metrics.font + FontRoles::BODY_BAND &&
          off_column?(line, metrics) && !shared.include?(self.class.left_edge(line))
      end
    end

    # A chapter title quotes its own running head, so only size tells them apart.
    def title_size?(line, metrics)
      metrics && FontRoles.quantize(line.font_size).to_f > metrics.font * TITLE_SIZE
    end

    # Marginalia set far below body size outside the text column is print noise, not narration.
    # A page set wholly in smaller type is a section of the book rather than a margin: what makes
    # a note a note is that it stands apart from the page it is printed on.
    def marginalia(lines, metrics)
      return [] unless metrics

      page_body = page_font_sizes(lines)
      lines.select do |line|
        size = FontRoles.quantize(line.font_size).to_f
        size < metrics.font * MARGINALIA_SIZE && size != page_body[line.page] && off_column?(line, metrics)
      end
    end

    def page_font_sizes(lines)
      lines.group_by(&:page).transform_values { |page_lines| mode_of(page_lines.map { |line| FontRoles.quantize(line.font_size) }) }
    end

    def off_column?(line, metrics) = (line.x.to_f - metrics.x).abs > metrics.width * OUTLIER_MARGIN

    def body_metrics(lines)
      width = lines.map { |line| line.page_width.to_f }.max.to_f
      x     = mode_of(lines.map { |line| (line.x.to_f / 10).round * 10 })
      # `size` would collide with Hash#size on the SymMash.
      font  = mode_of(lines.filter_map { |line| FontRoles.quantize(line.font_size) })
      SymMash.new(width: width, x: x, font: font) if width.positive? && x && font
    end

    def mode_of(values) = values.compact.tally.max_by { |_, count| count }&.first

    # ---------- cataloguing record ----------

    RIGHTS_PAGES = 8
    CATALOG_MARK = /\bis[bs]n\b|\bcd[du]\b|\bp\. cm\.|\bdc\d\d\b|catalogaç|cataloging/i
    # On such a page these lines are the record librarians need, not text to read out.
    RECORD_START = /\A(?:©|\(c\)|copyright|is[bs]n|cdd|cdu|p\.\s*cm\.|www\.|https?:|
                        dep(?:o|ó)sito\s+legal|printed\s+(?:in|on)|impreso\s+en|
                        all\s+rights\s+reserved|todos\s+os\s+direitos|todos\s+los\s+derechos|
                        [\p{L}'-]+,\s+[\p{L}'-]+,\s+\d{4})/xi
    RECORD_INSIDE = /\bis[bs]n[:\s]|\bcd[du][-:\s]|\b[ivx]+\.\s*(?:t(?:í|i)tul|title)|\bdc\d\d\b|
                     cat[a]?log|\A\p{Lu}{2}\d|\A[\w.+-]+@[\w.-]+\z/xi
    # The subject headings of a record run several numbered entries to the line.
    SUBJECT_ENTRY = /(?:\A|\s)\d{1,2}\.\s+\p{Lu}/
    RECORD_WORDS  = 5

    # The opening or closing pages carry a cataloguing record: the notice, the identifiers and
    # the shelf codes. The same page may still hold a dedication or an acknowledgement, so only
    # the record goes.
    def without_rights_record(lines_data)
      lines  = wrap(lines_data)
      pages  = lines.group_by(&:page)
      rights = record_pages(pages.keys.sort).select { |page| catalog_page?(pages[page]) }.to_set
      return lines_data if rights.empty?

      reject_lines(lines_data, lines) { |line| rights.include?(line.page) && record_line?(line.text) }
    end

    # A book prints its record at the front or at the back, never in the middle.
    def record_pages(pages) = pages.first(RIGHTS_PAGES) | pages.last(RIGHTS_PAGES)

    def catalog_page?(page_lines) = page_lines.map { |line| line.text.to_s }.join(' ').match?(CATALOG_MARK)

    def record_line?(text)
      value = text.to_s
      return true if value.match?(RECORD_START) || value.match?(RECORD_INSIDE)
      return true if value.scan(SUBJECT_ENTRY).size > 1

      # The subject headings of a record are a numbered list of two or three words each.
      TextHelpers.enumerated?(value) && value.split.size <= RECORD_WORDS
    end

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
    def without_contents(lines_data)
      lines    = wrap(lines_data)
      contents = contents_pages(lines.group_by(&:page))
      return lines_data if contents.empty?

      reject_lines(lines_data, lines) { |line| contents.include?(line.page) }
    end

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
    def without_index(lines_data)
      lines = wrap(lines_data)
      pages = index_pages(lines.group_by(&:page))
      return lines_data if pages.empty?

      reject_lines(lines_data, lines) { |line| pages.include?(line.page) }
    end

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

    # Endnotes are read where they are called, so the list they came from is not read again.
    def without_skipped_pages(lines_data)
      return lines_data if @skip_pages.blank?

      reject_lines(lines_data, wrap(lines_data)) { |line| @skip_pages.include?(line.page) }
    end

    # ---------- shared left edges ----------

    EDGE_TOLERANCE = 2

    # A left edge that repeats on a page is a block margin; a centred line has the page to itself.
    def self.shared_left_edges(lines)
      lines.group_by(&:page).each_with_object(Set.new) do |(page, page_lines), shared|
        counts = page_lines.map { |line| left_edge(line).last }.tally
        counts.each_key do |edge|
          near = counts.sum { |other, count| (other - edge).abs <= EDGE_TOLERANCE ? count : 0 }
          shared << [page, edge] if near > 1
        end
      end
    end

    def self.left_edge(line) = [line.page, line.x.to_f.round]
  end
end
