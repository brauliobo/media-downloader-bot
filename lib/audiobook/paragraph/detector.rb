require_relative '../line'
require_relative '../sentence'
require_relative '../paragraph'
require_relative 'factory'
require_relative '../../text_helpers'

module Audiobook
  class Paragraph
    # The grid a page is set on: the step between baselines, the margin its column keeps to and
    # whether the text is justified. The gaps between text boxes jitter in re-rendered PDFs and
    # go negative where glyphs overlap; the grid is stable because it is what the typesetter set.
    class PageGrid
      GAP_STEP      = 1.25
      INDENT_EM     = 0.6
      RAGGED_EM     = 2.0
      JUSTIFIED_MIN = 0.5
      FLUSH_RIGHT   = 2.0
      LABEL_WIDTH   = 0.7
      COLUMN_EDGE   = 2.0
      STEP_SHARE    = 0.05

      EMPTY = SymMash.new(
        step: 0.0, spacing: 0.0, column: 0.0, right: 0.0, justified: false, gaps: false, indents: false
      )

      def initialize(lines)
        @pages = lines.group_by(&:page_number).transform_values { |page_lines| measure(page_lines) }
      end

      # Consecutive baselines on one page sit a step apart; a paragraph opens with more than that.
      # Sources that carry no coordinates only report the gap between boxes, so fall back to it.
      def gap?(above, below)
        return false unless above && below && above.page_number == below.page_number

        grid = page(below)
        return below.top_spacing.to_f > grid.spacing * GAP_STEP unless grid.step.positive?

        (above.y_position.to_f - below.y_position.to_f) > grid.step * GAP_STEP
      end

      def indented?(line) = indent?(line, page(line).column)
      def at_column?(line) = (line.x_position.to_f - page(line).column).abs <= COLUMN_EDGE

      # In justified text a short line closes the paragraph; ragged-right text is all short lines.
      def ragged_end?(line)
        page(line).justified && line.x_max.to_f < page(line).right - line.font_size.to_f * RAGGED_EM
      end

      # A page with no paragraph gaps, no indents and a ragged right edge offers nothing to read.
      def flat?(line) = !page(line).gaps && !page(line).indents && !page(line).justified

      def short?(line)
        span = page(line).right - page(line).column
        span.positive? && line.x_max.to_f - line.x_position.to_f < span * LABEL_WIDTH
      end

      private

      def page(line) = @pages[line.page_number] || EMPTY

      def indent?(line, column) = line.x_position.to_f - column >= line.font_size.to_f * INDENT_EM

      def measure(page_lines)
        steps    = page_lines.each_cons(2)
          .map { |above, below| (above.y_position.to_f - below.y_position.to_f).round }.select(&:positive?)
        spacings = page_lines.map { |line| line.top_spacing.to_f }.select(&:positive?)
        step     = leading_of(steps).to_f
        spacing  = median_of(spacings).to_f
        column   = mode_of(page_lines.map { |line| line.x_position.to_f.round }).to_f
        right    = page_lines.map { |line| line.x_max.to_f }.max.to_f
        flush    = page_lines.count { |line| line.x_max.to_f >= right - FLUSH_RIGHT }
        measured = step.positive? ? [steps, step] : [spacings, spacing]

        SymMash.new(
          step: step, spacing: spacing, column: column, right: right,
          justified: right.positive? && page_lines.size > 2 && flush >= page_lines.size * JUSTIFIED_MIN,
          gaps:      measured.last.positive? && measured.first.any? { |value| value > measured.last * GAP_STEP },
          indents:   page_lines.any? { |line| indent?(line, column) }
        )
      end

      def mode_of(values) = values.tally.max_by { |_, count| count }&.first
      def median_of(values) = values.sort.then { |sorted| sorted[sorted.size / 2] }

      # The line leading is the tightest step the page repeats. Taking the commonest step instead
      # inverts the reading in a book whose paragraphs are one line long, and taking the smallest
      # follows a single pair of overlapping boxes.
      def leading_of(steps)
        floor = [2, (steps.size * STEP_SHARE).ceil].max
        steps.tally.select { |_, count| count >= floor }.keys.min || mode_of(steps)
      end
    end

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
              @breaks.break?(previous, line, buf, isolated: isolated?(idx - 1), starts_block: isolated?(idx))
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

    class BreakDetector
      def initialize(grid)
        @grid = grid
      end

      def break?(prev_line, line, buf, isolated: false, starts_block: false)
        buffer_text = buf.map(&:text).join(' ').strip
        # A footnote marker sits on its own line above the note it introduces.
        return false if TextHelpers.marker_line?(buffer_text)

        finished     = Sentence.ends_with_punctuation?(buffer_text)
        continuation = FontRoles.heading_continuation?(prev_line, line)
        # Emphasis that carries a sentence on in mid-flow is a run inside the paragraph, not a new block.
        emphasis_run = line.continues?(buffer_text) && !line.font_changed?(prev_line)

        return true  if structural?(prev_line, line, continuation, emphasis_run)
        return false if continuation || emphasis_run
        # A block opens with a capital or after the sentence before it closed; anything else is
        # the same sentence carrying on, whatever the page geometry measures.
        return false unless finished || line.starts_with_capital?

        return true if starts_block || (isolated && buf.one?)
        return true if buf.one? && label?(prev_line, line)

        layout?(prev_line, line, finished)
      end

      private

      # A change of language, style or role, a list label or a leader line closes the block
      # whatever the page geometry says, and whatever page it happens on.
      def structural?(prev_line, line, continuation, emphasis_run)
        return true if line.language != prev_line.language
        return true if TextHelpers.marker_line?(line.text)
        return true if TextHelpers.enumerated?(line.text) || FontRoles.labeled_line?(line)
        return true if TextHelpers.toc_entry?(prev_line.text)
        return true if font_changed?(prev_line, line, continuation, emphasis_run)

        !continuation && !emphasis_run && FontRoles.heading_item?(prev_line) != FontRoles.heading_item?(line)
      end

      def font_changed?(prev_line, line, continuation, emphasis_run)
        line.font_changed?(prev_line) ||
          (!emphasis_run && !continuation && !FontRoles.heading_item?(prev_line) && line.style_changed?(prev_line))
      end

      # "5. Time (how long to take the protocols)" names the block that follows; it is not part of it.
      def label?(prev_line, line)
        TextHelpers.enumerated?(prev_line.text) && line.starts_with_capital? &&
          !prev_line.ends_with_punctuation? && @grid.short?(prev_line)
      end

      # The grid marks the paragraphs out: an opening gap, an indented first line or the short
      # line that closed the one before. A page that shows none of that leaves only the old
      # reading, a finished sentence before a capital.
      def layout?(prev_line, line, finished)
        return true if @grid.gap?(prev_line, line)
        # A first-line indent steps in from the margin the block keeps to; the hanging indent of
        # a list item steps the other way, so the line above must itself sit at the column.
        return true if @grid.indented?(line) && @grid.at_column?(prev_line)
        return true if finished && @grid.ragged_end?(prev_line)

        finished && line.starts_with_capital? && @grid.flat?(line)
      end
    end
  end
end
