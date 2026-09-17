require 'set'
require_relative '../text_helpers'

module Audiobook
  # The notes of a book often sit together at the back instead of at the foot of each page,
  # numbered from one again under every chapter. Read in place they are an unbroken list of
  # citations; bound to the sentences that call them they become footnotes again.
  class Endnotes
    NOTES_TITLE  = /\A(?:notas?|notes|endnotes|refer[êe]ncias?|references)\s*\z/i
    GROUP_LABEL  = /\A(?:cap[íi]tulo|chapter|parte|part|introdu|pref[áa]cio|ep[íi]logo|
                        ap[êe]ndice|appendix|conclus|posf[áa]cio)/xi
    GROUP_NUMBER = /\A(?:cap[íi]tulo|chapter)\s*(\d+)/i
    # A group label runs into its first entry, whose text may start on the next line:
    # "Capítulo 1: Traumas perdidos 1. Wylie…" or "Capítulo 2: O Corpo Familiar 1."
    GROUP_OPENING = /\A(.*?)\s+(\d{1,3}\.(?:\s+\S.*)?)\z/
    ENTRY_START  = /\A(\d{1,3})\.(?:\s+(\S.*))?\z/
    # A wrapped label runs into its first entry: "encontrados 1. Mary Sykes Wylie…"
    ENTRY_OPENING = /(?:\A|\s)(\d{1,3})\.\s+(?=\S)/
    MIN_ENTRIES  = 3
    TITLE_LINES  = 4

    attr_reader :pages

    def self.none = new([])
    def self.from_lines(lines_data) = new(lines_data)

    def initialize(lines_data)
      @pages = Set.new
      @groups = {}
      parse(lines_data.map { |line| line.is_a?(SymMash) ? line : SymMash.new(line) })
    end

    def empty? = @groups.empty?

    # A note is looked for under the chapter that cites it, then under the only group there is.
    def entry(chapter, id)
      @groups.dig(chapter, id) || @groups.dig(nil, id) || (@groups.values.first[id] if @groups.one?)
    end

    private

    def parse(lines)
      pages = lines.group_by(&:page)
      start = section_start(pages)
      return unless start

      @pages = section_pages(pages, start)
      collect(@pages.sort.flat_map { |page| pages[page] }.map { |line| line.text.to_s.strip }.reject(&:empty?))
      @pages = Set.new if @groups.values.sum { |entries| entries.count { |_, text| text.present? } } < MIN_ENTRIES
      @groups = {} if @pages.empty?
    end

    # The section announces itself; a book that repeats the word over its pages does not.
    def section_start(pages)
      pages.keys.sort.reverse.find do |page|
        pages[page].first(TITLE_LINES).any? { |line| line.text.to_s.strip.match?(NOTES_TITLE) } &&
          numbered(pages[page]) + numbered(pages[page + 1] || []) >= MIN_ENTRIES
      end
    end

    def section_pages(pages, start)
      pages.keys.sort.select { |page| page >= start }
        .take_while { |page| page == start || numbered(pages[page]).positive? }.to_set
    end

    def numbered(page_lines) = page_lines.count { |line| line.text.to_s.strip.match?(ENTRY_START) }

    def collect(texts)
      group = nil
      id = nil
      texts.each do |text|
        label, text = split_opening(text)
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

    def group_key(label) = label[GROUP_NUMBER, 1]

    def add(group, id, text)
      entries = (@groups[group] ||= {})
      entries[id] ||= ''
      entries[id] = TextHelpers.join_pdf_lines([entries[id], text]) if text.present?
    end
  end
end
