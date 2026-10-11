module Audiobook
  module Parsers
    class Pdf
      # Pages laid out as tables are read row by row and folded into lines of their own.
      module Tables
        # A page given over to a table, and the number of them a table may run to before it is a
        # dataset rather than a passage.
        TABLE_PAGE  = 0.6
        TABLE_PAGES = 2

        def tabled_page(page)
          height = median_height(page.xpath('.//word')).to_f
          rows   = height.zero? ? [] : Table.rows_of(page, height)
          bands  = height.zero? ? [] : Table.bands(rows, height)
          Parsed.new(
            page, height, rows, bands, bands.map { |band| Table.rows(rows[band], height) },
            baseline_runs(page.xpath('.//line')).filter_map { |words| line_of(words, page) }
          )
        end

        # A table's own lines are replaced by the rows it was drawn to show, so every stage after
        # this one reads prose whether the page held a table or not. A table that runs over page
        # after page is a dataset rather than a passage, and is announced instead of read; the run
        # is only visible with every page of the range in hand.
        def fold_tables(parsed, lang)
          long = long_tables(parsed)
          parsed.each_with_index do |page, index|
            page.bands.each_with_index.reverse_each do |band, at|
              page.lines = fold_band(page.lines, page.rows[band], page.tables[at], page.height, lang, long[index])
            end
          end
        end

        # The row count to announce, per page, for a table that runs past more pages than a
        # listener will sit through: the first page of the run carries it and the rest read empty.
        def long_tables(parsed)
          tabled = parsed.map { |page| page.tables.sum(&:size) if page.bands.sum(&:size) >= page.rows.size * TABLE_PAGE }
          tabled.each_index.slice_when { |above, below| tabled[above].nil? || tabled[below].nil? }
            .each_with_object({}) do |run, long|
              next if tabled[run.first].nil? || run.size <= TABLE_PAGES

              total = run.sum { |index| tabled[index] }
              run.each_with_index { |index, at| long[index] = at.zero? ? total : 0 }
            end
        end

        def fold_band(lines, band, table, height, lang, long)
          inside = lines.select { |line| line.y_min.to_f.between?(band.first.first - 1, band.last.first + height) }
          return lines if inside.empty?

          spoken = Table.spoken(table, band.first.first, lang, long).map { |y, text| table_line(inside.first, y, height, text) }
          lines.flat_map { |line| line.equal?(inside.first) ? spoken : (inside.any? { |row| row.equal?(line) } ? [] : [line]) }
        end

        def table_line(model, y, height, text)
          model.merge(text: text, y_min: y, y_max: y + height, y: model.page_height.to_f - y - height)
        end

        def median_height(words)
          heights = words.map { |word| height_of(word) }.sort
          heights[heights.size / 2]
        end
      end
    end
  end
end
