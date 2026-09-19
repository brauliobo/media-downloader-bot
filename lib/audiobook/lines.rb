require 'set'
require_relative 'line'
require_relative 'page_filter'

module Audiobook
  # Turns the rows a parser extracted into Line objects. Everything a line needs to know about
  # its neighbours is settled here, because a Line on its own cannot see the page it sits on.
  module Lines
    ATTRIBUTES = %i[font_size page_width top_spacing bottom_spacing section_level language
                    alignment bold italic color font_name block].freeze

    def self.build(lines_data)
      rows = lines_data.map { |line| SymMash.wrap(line) }
      # A ragged block reads as centred line by line, so alignment is judged against the edges
      # the page repeats rather than against each line's own midpoint.
      shared = PageFilter.shared_left_edges(rows)

      verse = verse_pages(rows)

      rows.map { |row| line_from(row, shared, verse) }.reject(&:empty?)
    end

    # A page whose lines nearly all begin with a capital is verse: prose reaches two thirds at
    # most, because a sentence carries on past the line it started on. A list and a page set one
    # sentence to a line reach it too, and on those a line break already is a sentence break.
    VERSE_LINES = 8
    VERSE_SHARE = 0.9

    def self.verse_pages(rows)
      rows.group_by(&:page).select do |_, page_rows|
        lines = page_rows.reject { |row| row.text.to_s.split.size < 2 }
        lines.size >= VERSE_LINES &&
          lines.count { |row| row.text.to_s.match?(/\A\p{Lu}/) } >= lines.size * VERSE_SHARE
      end.keys.to_set
    end

    def self.line_from(row, shared, verse)
      Line.new(
        row.text,
        verse:       verse.include?(row.page),
        shared_edge: shared.include?(PageFilter.left_edge(row)),
        y_position:  row.y,
        page_number: row.page,
        x_position:  row.x,
        x_max:       row.x_max,
        **ATTRIBUTES.to_h { |attribute| [attribute, row[attribute]] }
      )
    end
  end
end
