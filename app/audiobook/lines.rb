require 'set'

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

      verse    = verse_pages(rows)
      measures = measures_of(rows)

      rows.map { |row| line_from(row, shared, verse, measures[row.page]) }.reject(&:empty?)
    end

    # The measure of a page is the right edge most of its lines end at: prose is set to it and a
    # heading is not, which is how a heading is told from body text set in the same type. Edges
    # jitter by a point or two, so they are counted in bands rather than one by one.
    MEASURE_BAND = 5

    def self.measures_of(rows)
      rows.group_by(&:page).transform_values do |page_rows|
        page_rows.map { |row| (row.x_max.to_f / MEASURE_BAND).round * MEASURE_BAND }
          .tally.max_by { |edge, count| [count, edge] }&.first
      end
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

    def self.line_from(row, shared, verse, measure)
      Line.new(
        row.text,
        verse:        verse.include?(row.page),
        page_measure: measure,
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
