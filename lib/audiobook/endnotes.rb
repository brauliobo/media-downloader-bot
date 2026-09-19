require 'set'
require_relative '../text_helpers'

module Audiobook
  # The notes of a book often sit together at the back instead of at the foot of each page,
  # numbered from one again under every chapter. Read in place they are an unbroken list of
  # citations; bound to the sentences that call them they become footnotes again.
  class Endnotes
    # The section names itself, sometimes with a qualifier: "Notas", "Notas Explicativas",
    # "Notes on the Text". Letter spacing splits the qualifier, so only the opening word counts.
    NOTES_TITLE  = /\A(?:notas?|notes|endnotes|refer[êe]ncias?|references)\b/i
    TITLE_WORDS  = 4
    GROUP_LABEL  = /\A(?:cap[íi]tulo|chapter|parte|part|introdu|pref[áa]cio|ep[íi]logo|
                        ap[êe]ndice|appendix|conclus|posf[áa]cio)/xi
    GROUP_NUMBER = /\A(?:cap[íi]tulo|chapter)\s*(\d+)/i
    # A section may head each group with the chapter's own numbered title instead of labelling it.
    GROUP_INDEX  = /\A(\d{1,3})[.)]\s+\S/
    # A group label runs into its first entry, whose text may start on the next line:
    # "Capítulo 1: Traumas perdidos 1. Wylie…" or "Capítulo 2: O Corpo Familiar 1."
    GROUP_OPENING = /\A(.*?)\s+(\d{1,3}\.(?:\s+\S.*)?)\z/
    # An entry opens with its number. The period after it is often missing, and then the note
    # has to read like a title for the number to be a label rather than a quantity.
    ENTRY_START  = /\A(\d{1,3})(?:\.\s+|\.\z|\s+(?=[“"«\p{Lu}]))(.*)\z/u
    # A wrapped label runs into its first entry: "encontrados 1. Mary Sykes Wylie…"
    ENTRY_OPENING = /(?:\A|\s)(\d{1,3})\.\s+(?=\S)/
    # The entries are the bulk of the section, so a line set larger than them heads a group.
    LABEL_SIZE   = 1.1
    MIN_ENTRIES  = 3
    TITLE_LINES  = 4

    attr_reader :pages

    def self.none = new([])
    def self.from_lines(lines_data) = new(lines_data)

    def initialize(lines_data)
      @pages = Set.new
      @groups = {}
      parse(lines_data.map { |line| SymMash.wrap(line) })
    end

    def empty? = @groups.empty?

    # A note is looked for under the chapter that cites it, then under the group the section
    # lists at that position, and last under the only group there is.
    def entry(chapter, id, ordinal = nil)
      (chapter && @groups.dig(chapter, id)) || ordered(ordinal, id) || @groups.dig(nil, id) ||
        (@groups.values.first[id] if @groups.one?)
    end

    def ordered(ordinal, id)
      return unless ordinal && ordinal >= 0

      @groups.values[ordinal]&.[](id)
    end

    private

    def parse(lines)
      pages = lines.group_by(&:page)
      start = section_start(pages)
      return unless start

      @pages = section_pages(pages, start)
      collect(@pages.sort.flat_map { |page| pages[page] }.reject { |row| row.text.to_s.strip.empty? })
      @pages = Set.new if @groups.values.sum { |entries| entries.count { |_, text| text.present? } } < MIN_ENTRIES
      @groups = {} if @pages.empty?
    end

    # The section announces itself; a book that repeats the word over its pages does not.
    def section_start(pages)
      pages.keys.sort.reverse.find do |page|
        pages[page].first(TITLE_LINES).any? { |line| notes_title?(line.text) } &&
          numbered(pages[page]) + numbered(pages[page + 1] || []) >= MIN_ENTRIES
      end
    end

    def notes_title?(text)
      title = text.to_s.strip
      title.match?(NOTES_TITLE) && title.split.size <= TITLE_WORDS
    end

    def section_pages(pages, start)
      pages.keys.sort.select { |page| page >= start }
        .take_while { |page| page == start || numbered(pages[page]).positive? }.to_set
    end

    def numbered(page_lines) = page_lines.count { |line| line.text.to_s.strip.match?(ENTRY_START) }

    def collect(rows)
      sizes = entry_sizes(rows)
      group = nil
      id = nil
      rows.each do |row|
        text = row.text.to_s.strip
        label, text = group_heading(row, sizes[row.page]) || split_opening(text)
        group = group_key(label) if label
        id = nil if label

        if (opening = text&.match(ENTRY_START))
          id = opening[1]
          add(group, id, opening[2])
        elsif id.nil? && group && (opening = text&.match(ENTRY_OPENING))
          id = opening[1]
          add(group, id, text[opening.end(0)..])
        elsif id && text
          add(group, id, text)
        end
      end
    end

    # "Capítulo 2: O Corpo Familiar 1. Sadler, Embriologia…" opens a group and its first entry.
    def split_opening(text)
      return [nil, text] unless text.match?(GROUP_LABEL)

      opening = text.match(GROUP_OPENING)
      opening ? [opening[1], opening[2]] : [text, nil]
    end

    def group_key(label) = label[GROUP_NUMBER, 1] || label[GROUP_INDEX, 1]

    # The entries are the bulk of a page. Sizes drift from page to page in a re-rendered PDF,
    # so each page is measured against itself.
    def entry_sizes(rows)
      rows.group_by(&:page).transform_values do |page_rows|
        page_rows.map { |row| row.font_size.to_f.round(1) }.select(&:positive?).tally.max_by(&:last)&.first
      end
    end

    # A line set larger than the entries around it heads a group, but only where it names one:
    # a watermark or a running head is merely large.
    def group_heading(row, body)
      text = row.text.to_s.strip
      [text, nil] if body.present? && row.font_size.to_f > body * LABEL_SIZE && group_key(text)
    end

    def add(group, id, text)
      entries = (@groups[group] ||= {})
      entries[id] ||= ''
      entries[id] = TextHelpers.join_pdf_lines([entries[id], text]) if text.present?
    end
  end
end
