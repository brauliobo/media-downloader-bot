module Audiobook
  class FontRoles
    # A line weighed against its neighbours: its size, alignment and whether it opens a heading or continues one.
    module LineJudgement
      def quantize(size)
        return if size.nil? || size.to_f <= 0

        (size.to_f * 2).round / 2.0
      end

      def size_of(line) = quantize(line.font_size)

      def alignment_for(x:, x_max:, page_width:, shared_edge: false)
        width = page_width.to_f
        return unless width.positive?

        # A ragged block reads as centred line by line; its lines give each other away by
        # starting at one margin, which a centred line never shares.
        return :left if shared_edge

        left       = x.to_f
        right_edge = x_max.to_f
        right_edge = left if right_edge <= left
        right      = width - right_edge
        span       = right_edge - left
        mid_err    = ((left + right_edge) / 2.0 - width / 2.0).abs

        if mid_err <= width * 0.08 && left > width * CENTER_SIDE_MIN && right > width * CENTER_SIDE_MIN &&
            span <= width * CENTER_SPAN_MAX
          :center
        elsif right + 2 < left * 0.5 && left > width * 0.25
          :right
        else
          :left
        end
      end

      # Glyph coverage shifts reported sizes slightly within the same run, so compare with a tolerance.
      SIZE_TOLERANCE = 0.5

      SIZE_RATIO     = 0.06

      def same_size?(a, b)
        sa, sb = size_of(a), size_of(b)
        sa && sb && (sa - sb).abs <= [SIZE_TOLERANCE, [sa, sb].max * SIZE_RATIO].max
      end

      def heading_item?(line)
        if (roles = current)
          role = roles.role_for(line)
          return true if HEADING_LIKE_ROLES.include?(role)
          return false if %i[body footnote].include?(role)
        end
        # A heading is a label and stops short of the margin; a line that runs to the measure the
        # page keeps is body copy, whatever its wording looks like.
        line.heading_like? && !line.runs_measure?
      end

      def heading_continuation?(prev, line)
        return false unless prev && line && heading_item?(prev)
        # A heading wrapped over a page break is a rarity; two headings on facing pages are not.
        return false if prev.page_number != line.page_number
        return false unless same_size?(prev, line)
        return false if long_body_line?(line) || labeled_line?(line)
        heading_item?(line) || same_emphasis?(prev, line)
      end

      # "Nota:", "CD = clorito sódico" and "CDS - disolución" all label the text that follows.
      LABEL = /\A[\p{L}\p{N}.]+\s*(?:[:=]|[-–—]\s)/u

      def labeled_line?(line) = line.text.to_s.match?(LABEL)

      def long_body_line?(line)
        line.word_count > SHORT_CENTER_WORDS && !heading_item?(line)
      end

      def same_emphasis?(a, b)
        !!a&.bold == !!b&.bold
      end

      def flow_alignment(item, text: nil, paragraph: false)
        align = alignment_of(item)
        return unless align

        body = text || item.text
        return if paragraph && align == :center && body.to_s.split.size >= SHORT_CENTER_WORDS
        return if paragraph && align == :left

        align
      end
    end
  end
end
