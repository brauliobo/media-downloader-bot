require_relative 'line'
require_relative 'page_filter'

module Audiobook
  # Turns the rows a parser extracted into Line objects. Everything a line needs to know about
  # its neighbours is settled here, because a Line on its own cannot see the page it sits on.
  module Lines
    ATTRIBUTES = %i[font_size page_width top_spacing bottom_spacing section_level language
                    alignment bold italic color font_name block].freeze

    def self.build(lines_data)
      rows = lines_data.map { |line| line.is_a?(SymMash) ? line : SymMash.new(line) }
      # A ragged block reads as centred line by line, so alignment is judged against the edges
      # the page repeats rather than against each line's own midpoint.
      shared = PageFilter.shared_left_edges(rows)

      rows.map { |row| line_from(row, shared) }.reject(&:empty?)
    end

    def self.line_from(row, shared)
      Line.new(
        row.text,
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
