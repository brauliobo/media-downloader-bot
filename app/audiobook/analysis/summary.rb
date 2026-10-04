module Audiobook
  module Analysis
    # The table a run leaves behind, and the only question usually asked of it: what did this
    # change do to every book at once.
    module Summary
      SEPARATOR = "\t".freeze
      # Timing says nothing about assembly and never matches between two runs.
      IGNORED   = %w[secs].freeze

      def self.tsv(rows)
        columns = rows.flat_map { |_, counts| counts.keys }.uniq
        table   = rows.map { |name, counts| [name, *columns.map { |column| counts[column] || 0 }] }
        [['book', *columns], *table].map { |row| row.join(SEPARATOR) }.join("\n")
      end

      def self.read(path)
        rows    = File.readlines(path).map { |line| line.chomp.split(SEPARATOR) }
        columns = rows.shift.drop(1)
        rows.to_h { |name, *values| [name, columns.zip(values.map(&:to_f)).to_h] }
      end

      def self.totals(path)
        read(path).values.each_with_object(Hash.new(0)) do |counts, totals|
          counts.each { |column, value| totals[column] += value }
        end
      end

      # Defects are meant to reach zero; shape says how the books are written and never will.
      # Summing the two is what makes a book look worse the more of it is read correctly.
      def self.diff(before, after)
        left, right = totals(before), totals(after)
        defects, shape = columns(left, right).partition { |column| !Detectors::SHAPE.include?(column.to_sym) }
        [*defects.map { |column| line(column, left[column], right[column]) }, '', '-- shape --',
         *shape.map { |column| line(column, left[column], right[column]) }]
      end

      def self.per_book(before, after)
        left, right = read(before), read(after)
        (left.keys & right.keys).filter_map do |book|
          moved = columns(left[book], right[book])
            .filter_map { |column| "#{column} #{number(left[book][column])}→#{number(right[book][column])}" if left[book][column] != right[book][column] }
          "#{book.ljust(NAME_WIDTH + 2)}#{moved.join('  ')}" if moved.any?
        end
      end

      def self.columns(left, right) = (left.keys | right.keys).reject { |column| IGNORED.include?(column) }

      def self.line(column, before, after)
        delta = after - before
        format('%-16s %9s → %-9s %s', column, number(before), number(after),
               delta.zero? ? '' : format('%+g', delta))
      end

      def self.number(value) = value.to_i == value ? value.to_i : value.round(1)
    end
  end
end
