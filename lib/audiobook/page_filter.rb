require 'set'
require_relative '../text_helpers'
require_relative 'font_roles'

module Audiobook
  # Decides which extracted lines belong to the narration. Page furniture, the cataloguing
  # record and the contents pages are all printed for a reader who can see the page, and say
  # nothing to a listener.
  class PageFilter
    FILTERS = %i[furniture rights_record contents skipped_pages].freeze

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

    def wrap(lines_data) = lines_data.map { |line| line.is_a?(SymMash) ? line : SymMash.new(line) }

    def reject_lines(lines_data, lines, &drop)
      kept = lines_data.select.with_index { |_, idx| !drop.call(lines[idx]) }
      kept.size == lines_data.size ? lines_data : kept
    end

    # ---------- page furniture ----------

    FOLIO           = /\A[ivxlcdm\d]{1,7}[.\]]?\z/i
    FURNITURE_WORDS = 8
    OUTLIER_MARGIN  = 0.1
    MARGIN_BAND     = 0.15
    MARGINALIA_SIZE = 0.55
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
      edges   = pages.values.map { |page_lines| edge_lines(page_lines) }
      # A re-rendered PDF reflows folios and running heads into the text, so the two patterns
      # that name themselves are also looked for in the page bands and outside the column.
      parked  = edges.zip(pages.values).map do |edge, page_lines|
        edge | margin_band(page_lines) | off_column_lines(page_lines, metrics)
      end
      folios = parked.flatten.select { |line| folio?(line, pages[line.page]) }
      (folios + repeated_margins(parked, folios, pages.size, metrics) +
        column_outliers(edges, folios, metrics, lines) + marginalia(lines, metrics)).to_set
    end

    def short_line?(line) = line.text.to_s.split.size <= FURNITURE_WORDS

    # The outermost lines of a page are where a header or footer lands when nothing else moved it.
    def edge_lines(page_lines) = page_lines.values_at(0, 1, -2, -1).compact.uniq.select { |line| short_line?(line) }

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
    def repeated_margins(margins, folios, page_count, metrics)
      edges  = margins.map { |page_edges| page_edges - folios }
      counts = edges.flat_map { |page_edges| page_edges.map { |line| TextHelpers.comparable_key(line.text) }.uniq }.tally
      limit  = [[(page_count * 0.3).ceil, 3].min, 2].max
      edges.flatten.select do |line|
        counts[TextHelpers.comparable_key(line.text)] >= limit && !title_size?(line, metrics)
      end
    end

    # A running head or watermark sits at the page edge outside the column the body keeps to,
    # and stands alone there: an indented line of verse shares its margin with its block.
    def column_outliers(edges, folios, metrics, lines)
      return [] unless metrics

      shared = shared_left_edges(lines)
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
    def marginalia(lines, metrics)
      return [] unless metrics

      lines.select do |line|
        FontRoles.quantize(line.font_size).to_f < metrics.font * MARGINALIA_SIZE && off_column?(line, metrics)
      end
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
                        dep[oó]sito\s+legal|printed\s+(?:in|on)|impreso\s+en|
                        all\s+rights\s+reserved|todos\s+os\s+direitos|todos\s+los\s+derechos|
                        [\p{L}'-]+,\s+[\p{L}'-]+,\s+\d{4})/xi
    RECORD_INSIDE = /\bis[bs]n[:\s]|\bcd[du][-:\s]|\b[ivx]+\.\s*(?:t[íi]tul|title)|\bdc\d\d\b|
                     cat[a]?log|\A\p{Lu}{2}\d|\A[\w.+-]+@[\w.-]+\z/xi
    # The subject headings of a record run several numbered entries to the line.
    SUBJECT_ENTRY = /(?:\A|\s)\d{1,2}\.\s+\p{Lu}/
    RECORD_WORDS  = 5

    # The opening pages carry a cataloguing record: the notice, the identifiers and the shelf
    # codes. The same page may still hold a dedication or an acknowledgement, so only the
    # record goes.
    def without_rights_record(lines_data)
      lines  = wrap(lines_data)
      pages  = lines.group_by(&:page)
      rights = pages.keys.sort.first(RIGHTS_PAGES).select { |page| catalog_page?(pages[page]) }.to_set
      return lines_data if rights.empty?

      reject_lines(lines_data, lines) { |line| rights.include?(line.page) && record_line?(line.text) }
    end

    def catalog_page?(page_lines) = page_lines.map { |line| line.text.to_s }.join(' ').match?(CATALOG_MARK)

    def record_line?(text)
      value = text.to_s
      return true if value.match?(RECORD_START) || value.match?(RECORD_INSIDE)
      return true if value.scan(SUBJECT_ENTRY).size > 1

      # The subject headings of a record are a numbered list of two or three words each.
      TextHelpers.enumerated?(value) && value.split.size <= RECORD_WORDS
    end

    # ---------- contents pages ----------

    CONTENTS_TITLE = /\A(?:contents|table\s+of\s+contents|conte[úu]dos?|sum[áa]rio|[íi]ndice|contenido|
                          tabela?\s+de\s+conte[úu]dos?|inhalt)\b/xi
    CHAPTER_LABEL  = /\A(?:cap[íi]tulo|chapter|parte|part|se[cç][çc]?[ãa]o|anexo|ap[êe]ndice|appendix)
                       \s*(?:\d|[ivxlc]+\b)/xi
    CONTENTS_ENTRIES = 5
    LISTED_ENTRIES   = 3

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
      pages.keys.sort.each_with_object(Set.new) do |page, found|
        texts = pages[page].map { |line| line.text.to_s.strip }.reject(&:empty?)
        next if texts.size < LISTED_ENTRIES

        entries = texts.count { |text| contents_entry?(text) }
        listed  = entries + texts.count { |text| text.match?(/\S\s\d{1,4}\z/) }
        opened  = found.include?(page - 1) || texts.first(3).any? { |text| text.match?(CONTENTS_TITLE) }
        found << page if entries >= CONTENTS_ENTRIES || (opened && listed >= LISTED_ENTRIES)
      end
    end

    def contents_entry?(text) = TextHelpers.toc_entry?(text) || text.match?(CHAPTER_LABEL)

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

    def shared_left_edges(lines) = self.class.shared_left_edges(lines)
  end
end
