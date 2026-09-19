module Audiobook
  module Parsers
    # A table is drawn for the eye: a band of rows divided into the same columns. Read down the
    # page, as lines that happen to share a baseline, it comes out as a list of names and numbers
    # with nothing holding them together. Read across, each cell under the name of its column, it
    # says what it was printed to say.
    module Table
      # A cell is a run of words with a gap far wider than a word space before the next one, so a
      # line of prose is one cell however its words line up with the line above.
      GAP_RATIO  = 1.5
      CELLS      = 2
      COLUMNS    = 3
      # A band is a run of such rows, and a cell that wraps puts a row inside one that is not.
      ROWS       = 6
      WRAP       = 2
      # The cells of a row sit on one baseline; a cell that wraps opens a row of its own.
      ROW_JITTER = 0.25

      # Where the table bands sit in a page's rows, each as the range of rows it covers.
      def self.bands(rows, height)
        rows.each_index.select { |index| cells(rows[index].last, height).size >= CELLS }
          .slice_when { |above, below| below > above + WRAP }
          .select { |run| run.size >= ROWS && columns(rows[run.first..run.last], height) >= COLUMNS }
          .map { |run| run.first..run.last }
      end

      # The page's rows, a row being the cells that sit on one baseline.
      def self.rows_of(page, height)
        page.xpath('.//word').sort_by { |word| word['yMin'].to_f }
          .slice_when { |above, below| below['yMin'].to_f - above['yMin'].to_f > height * ROW_JITTER }
          .map { |words| [words.first['yMin'].to_f, words] }
      end

      # How many columns a band is divided into: the cells of its rows, overlapping ones counted
      # once. Rows of a single cell are left out, or a line of prose would span the lot.
      def self.columns(band, height)
        divided = band.map { |_, words| cells(words, height) }.select { |row| row.size >= CELLS }
        merged(divided.flatten(1)).size
      end

      def self.merged(cells)
        cells.map { |left, right, _| [left, right] }.sort.each_with_object([]) do |(left, right), columns|
          last = columns.last
          last && left <= last.last ? last[1] = [last.last, right].max : columns << [left, right]
        end
      end

      # A cell is a run of words with no wide gap inside it.
      def self.cells(words, height)
        words.sort_by { |word| word['xMin'].to_f }
          .slice_when { |left, right| right['xMin'].to_f - left['xMax'].to_f > height * GAP_RATIO }
          .map { |run| [run.first['xMin'].to_f, run.last['xMax'].to_f, run.map(&:text).join(' ')] }
      end

      # What a table should be read as: one line per row, or one line saying how long it is where
      # it is too long to read, and nothing where that has already been said of an earlier page.
      def self.spoken(table, top, language, long = nil)
        return long.to_i.zero? ? [] : [[top, announced(long, language)]] if long
        return [] if table.empty?

        labels = headings(table)
        (labels ? table.drop(1) : table).map { |y, cells| [y, sentence(labels, cells)] }
      end

      # A row is what lines up with an entry in the first column: a cell that wraps sits a line
      # above or below the entry it belongs to, and belongs to the entry it is nearest.
      def self.rows(band, height)
        placed = band.flat_map { |y, words| cells(words, height).map { |left, right, text| [left, right, y, text] } }
        left   = placed.map(&:first).min
        spine  = placed.select { |x, _, _, _| x - left <= height }.map { |_, _, y, _| y }.uniq

        return [] if spine.empty?

        placed.group_by { |_, _, y, _| spine.min_by { |anchor| (anchor - y).abs } }
          .sort_by(&:first).map { |anchor, group| [anchor, column_texts(group)] }
      end

      # Cells whose columns overlap are one column, read top to bottom.
      def self.column_texts(placed)
        placed.sort_by(&:first).slice_when { |(_, right, _, _), (left, _, _, _)| left > right }
          .map { |column| column.sort_by { |_, _, y, _| y }.map(&:last).join(' ') }
      end

      # The first row names the columns where it carries no figures of its own.
      def self.headings(table)
        labels = table.first.last
        labels unless labels.any? { |cell| cell.match?(/\d/) }
      end

      def self.sentence(labels, cells)
        "#{cells.each_with_index.map { |cell, at| labels&.[](at) ? "#{labels[at]}: #{cell}" : cell }.join('; ')}."
      end

      def self.announced(rows, language) = I18n.t('audiobook.table.long', rows: rows, locale: language || :en)
    end
  end
end
