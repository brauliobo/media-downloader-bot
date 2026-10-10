module Audiobook
  class Paragraph
    class BreakDetector
      def initialize(grid)
        @grid = grid
      end

      def break?(prev_line, line, buf, isolated: false, fenced: false, block_break: false)
        buffer_text = buf.map(&:text).join(' ').strip
        # A footnote marker sits on its own line above the note it introduces.
        return false if Markers.line?(buffer_text)

        finished     = Text::Punctuation.closes?(buffer_text)
        continuation = FontRoles.heading_continuation?(prev_line, line)
        # Emphasis that carries a sentence on in mid-flow is a run inside the paragraph, not a new block.
        emphasis_run = line.continues?(buffer_text) && !line.font_changed?(prev_line)

        return true  if structural?(prev_line, line, continuation, emphasis_run)
        # A heading wrapping over two lines is one heading however the source divided it.
        return false if continuation
        # The source drew this boundary itself. A hard break in markup is deliberate: it sets a
        # line of verse or an item of a list, neither of which the prose reading below would part.
        return true  if block_break
        return false if emphasis_run
        # A block opens with a capital or after the sentence before it closed, and never with the
        # quote that closes the one before; anything else is the same sentence carrying on,
        # whatever the page geometry measures.
        return false if line.closes_quote?
        return false unless finished || line.starts_with_capital?

        return true if fenced || (isolated && buf.one?)
        return true if buf.one? && label?(prev_line, line)

        layout?(prev_line, line, finished)
      end

      private

      # A change of language, style or role, a list label or a leader line closes the block
      # whatever the page geometry says, and whatever page it happens on.
      def structural?(prev_line, line, continuation, emphasis_run)
        return true if line.language != prev_line.language
        return true if Markers.line?(line.text)
        return true if ListMark.enumerated?(line.text) || FontRoles.labeled_line?(line)
        return true if Contents.entry?(prev_line.text)
        return true if font_changed?(prev_line, line, continuation, emphasis_run)

        !continuation && !emphasis_run && FontRoles.heading_item?(prev_line) != FontRoles.heading_item?(line)
      end

      def font_changed?(prev_line, line, continuation, emphasis_run)
        line.font_changed?(prev_line) ||
          (!emphasis_run && !continuation && !FontRoles.heading_item?(prev_line) && line.style_changed?(prev_line))
      end

      # "5. Time (how long to take the protocols)" names the block that follows; it is not part of it.
      def label?(prev_line, line)
        ListMark.enumerated?(prev_line.text) && line.starts_with_capital? &&
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
