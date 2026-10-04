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
        pages  = lines.group_by(&:page_number)
        @pages = pages.transform_values { |page_lines| measure(page_lines) }
        @steps = pages.transform_values { |page_lines| steps_by_size(page_lines) }
      end

      # Consecutive baselines on one page sit a step apart; a paragraph opens with more than that.
      # Sources that carry no coordinates only report the gap between boxes, so fall back to it.
      def gap?(above, below)
        return false unless above && below && above.page_number == below.page_number

        grid = page(below)
        step = step_for(below)
        step = grid.step unless step.positive?
        return below.top_spacing.to_f > grid.spacing * GAP_STEP unless step.positive?

        (above.y_position.to_f - below.y_position.to_f) > step * GAP_STEP
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
      def step_for(line) = @steps.dig(line.page_number, FontRoles.quantize(line.font_size)).to_f

      # A page set in two sizes is set on two grids: the leading of an epigraph is not that of
      # the body, and one step for the whole page makes every line of the body look like the
      # opening of a paragraph. Only a size that repeats a leading has a grid of its own; three
      # headings a page apart share a size and no leading at all.
      REPEATED_STEPS = 3

      def steps_by_size(page_lines)
        page_lines.each_cons(2).group_by { |_, below| FontRoles.quantize(below.font_size) }
          .filter_map do |size, pairs|
            steps = pairs.map { |above, below| (above.y_position.to_f - below.y_position.to_f).round }.select(&:positive?)
            leading = steps.tally.select { |_, count| count >= REPEATED_STEPS }.keys.min
            [size, leading.to_f] if leading
          end.to_h
      end

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
  end
end
