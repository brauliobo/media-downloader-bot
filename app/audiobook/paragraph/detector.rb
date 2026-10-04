module Audiobook
  class Paragraph

    class Detector
      def self.discover_from_lines(lines, max_sentence_chars: Factory::MAX_SENTENCE_CHARS)
        new(lines, max_sentence_chars: max_sentence_chars).detect
      end

      # Where a block ends is the hardest call the assembly makes, so a caller can watch it being
      # made without standing in the middle of it.
      def self.observe(listener)
        previous = Thread.current[:audiobook_break_observer]
        Thread.current[:audiobook_break_observer] = listener
        yield
      ensure
        Thread.current[:audiobook_break_observer] = previous
      end

      def self.observer = Thread.current[:audiobook_break_observer]

      def initialize(lines, max_sentence_chars: Factory::MAX_SENTENCE_CHARS)
        @lines = strip_contents_numbers(lines)
        @max_sentence_chars = max_sentence_chars
        @grid = PageGrid.new(@lines)
        @breaks = BreakDetector.new(@grid)
      end

      def detect
        return [] if @lines.empty?

        items = []
        buf = []
        start_idx = 0
        start_page = nil
        # The line last seen, which is where the block reaches to on the page; the buffer may hold
        # a joined line whose coordinates are those of the fragment that opened it.
        previous = nil

        @lines.each_with_index do |line, idx|
          start_page ||= line.page_number

          if previous && buf.any?
            # Dehyphenate across lines
            if previous.ends_with_hyphen? && line.starts_with_lowercase?
              buf[-1] = Line.new(buf.last.dehyphenate(line.text), **buf.last.style_attrs)
              previous = line
              next
            end

            if buf.one? && oversized_initial?(previous, line)
              # Machine translation replaces the word a drop cap opened, leaving the letter orphaned.
              opens = line.starts_with_lowercase?
              buf = [opens ? Line.new("#{buf.last.text}#{line.text}", **line.style_attrs) : line]
              (start_page, start_idx = line.page_number, idx) unless opens
              previous = line
              next
            end
          end

          if previous && buf.any? &&
              @breaks.break?(previous, line, buf, isolated: isolated?(idx - 1), fenced: isolated?(idx),
                             block_break: previous.new_block?(line))
            self.class.observer&.call(previous, line, buf, @grid)
            items.concat(flush(buf, start_page, start_idx))
            buf = [line]
            start_idx = idx
            start_page = line.page_number
          else
            buf << line
          end
          previous = line
        end

        items.concat(flush(buf, start_page, start_idx)) if buf.any?

        items.reject { |data| data[:item].is_a?(Paragraph) && data[:item].empty? }
      end

      private

      def flush(buf, start_page, start_idx)
        Factory.create_items_from_lines(
          buf, start_page,
          max_sentence_chars: @max_sentence_chars,
          isolated: buf.one? && isolated?(start_idx)
        )
      end

      # An oversized single letter opening a paragraph is a drop cap, not a heading.
      DROP_CAP_RATIO = 1.8

      def oversized_initial?(prev_line, line)
        prev_line.text.match?(/\A\p{Lu}\z/u) && prev_line.font_size.to_f >= line.font_size.to_f * DROP_CAP_RATIO
      end

      # A line fenced by blank space above and below stands on its own, like a heading. A page
      # edge fences it too, but on its own it says nothing: a paragraph runs across one.
      def isolated?(idx)
        return false if idx.nil? || idx.negative? || idx >= @lines.size

        fences = [fence(@lines[idx - 1], @lines[idx], first: idx.zero?), fence(@lines[idx], @lines[idx + 1])]
        fences.all? && fences.include?(:gap)
      end

      def fence(above, below, first: false)
        return :edge if first || above.nil? || below.nil? || above.page_number != below.page_number

        :gap if @grid.gap?(above, below)
      end

      # An entry beside leader lines that ends in a number is a contents line whose leaders were lost.
      def strip_contents_numbers(lines)
        lines.each_with_index.map do |line, idx|
          next line if TextHelpers.toc_entry?(line.text) || !line.text.match?(/\S\s\d{1,4}\z/)

          beside = [idx.positive? ? lines[idx - 1] : nil, lines[idx + 1]].compact
            .select { |other| other.page_number == line.page_number }
          next line unless beside.any? { |other| TextHelpers.toc_entry?(other.text) }

          Line.new(line.text.sub(/\s+\d{1,4}\z/, ''), **line.style_attrs)
        end
      end
    end
  end
end
