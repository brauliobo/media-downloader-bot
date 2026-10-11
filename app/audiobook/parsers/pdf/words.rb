module Audiobook
  module Parsers
    class Pdf
      # Words as the page lays them out become lines: the ones on one baseline, the gaps between letters and the raised markers.
      module Words
        # Words closer than this fraction of their height belong to the same word (small caps runs).
        WORD_GAP_RATIO     = 0.05
        BASELINE_TOLERANCE = 0.5

        # Fragments of one justified line sit within a couple of spaces; a contents entry is further from its folio.
        ADJACENT_GAP_RATIO = 1.75

        # Letter-spaced type, and the small capitals a re-rendered PDF splits the same way, reach
        # the text layer one letter to a word and are read out letter by letter. A run of them has
        # gaps of two sizes and no others: between two letters of a word and between two words,
        # and the widest step between the two is where the words divide. A line may letter-space a
        # phrase and set the rest of itself normally, so the runs are read one at a time.
        LETTER_RUN  = 3
        LETTER_STEP = 1.5

        def line_of(words, page)
          baseline    = word_baseline(words)
          text        = line_text(words, baseline)
          page_height = page['height'].to_f
          return if text.empty?

          SymMash.new(
            text:       text,
            font_size:  line_font_size(words, baseline),
            # The baseline is where the line really sits; box tops move with the tallest glyph.
            y:          page_height - baseline,
            x:          words.map { |word| word['xMin'].to_f }.min,
            x_max:      words.map { |word| word['xMax'].to_f }.max,
            page_width:  page['width'].to_f,
            page_height: page_height,
            y_min:       words.map { |word| word['yMin'].to_f }.min,
            y_max:       words.map { |word| word['yMax'].to_f }.max
          )
        end

        # Justified text and page-number columns come out as several lines on one baseline, and a
        # re-rendered PDF puts each fragment in its own block, so rejoin what sits side by side.
        def baseline_runs(lines)
          slices = lines.group_by(&:parent).values.flat_map { |block| baseline_slices(block) }
          adopt_bullet_runs(fold_adjacent_runs(slices)).map { |words| words.sort_by { |word| word['xMin'].to_f } }
        end

        def fold_adjacent_runs(slices)
          slices.each_with_object([]) do |words, runs|
            side_by_side?(runs.last, words) ? runs.last.concat(words) : runs << words
          end
        end

        # A bullet column is often set as one block of its own, so a bullet never neighbours the entry it opens.
        def adopt_bullet_runs(runs)
          runs.reject do |words|
            next false unless bullet_run?(words)

            entry = runs.find { |other| !other.equal?(words) && side_by_side?(words, other) }
            entry&.concat(words)
          end
        end

        def bullet_run?(words)
          text = words.map(&:text).join.strip
          text.present? && ListMark::BULLETS.include?(text)
        end

        def baseline_slices(block)
          block.slice_when { |prev, line| !same_baseline?(prev, line) }
            .map { |slice| slice.flat_map { |line| line.xpath('./word').to_a } }
        end

        def side_by_side?(run, words)
          return false if run.blank? || words.blank?

          left, right = run.max_by { |word| word['xMax'].to_f }, words.min_by { |word| word['xMin'].to_f }
          gap = right['xMin'].to_f - left['xMax'].to_f
          same_baseline?(left, right) && gap >= 0 && gap < [height_of(left), height_of(right)].max * ADJACENT_GAP_RATIO
        end

        def same_baseline?(above, below)
          (below['yMin'].to_f - above['yMin'].to_f).abs <= [height_of(above), height_of(below)].min * BASELINE_TOLERANCE
        end

        def height_of(node) = node['yMax'].to_f - node['yMin'].to_f

        def line_text(words, baseline = word_baseline(words))
          spaced   = letter_gaps(words.to_a)
          previous = nil
          words.each_with_index.map do |word, at|
            marker = superscript_marker?(word, baseline)
            text   = marker ? Markers.wrap(word.text) : word.text
            # A footnote call belongs to the word it follows, however wide a gap the raised glyph leaves.
            text = "#{word_separator(previous, word, spaced[at])}#{text}" if previous && !marker
            previous = word
            text
          end.join.strip
        end

        def letter_gaps(words)
          words.each_index.select { |at| single?(words[at]) }
            .slice_when { |above, below| below > above + 1 }
            .select { |run| run.count { |at| letter?(words[at]) } >= LETTER_RUN }
            .each_with_object({}) do |run, gaps|
              gap = letter_gap(words[run.first..run.last])
              run.each { |at| gaps[at] = gap } if gap
            end
        end

        # A digit or a mark set among the letters belongs to the run; letters alone declare one.
        def single?(word) = word.text.to_s.strip.length == 1

        def letter?(word) = word.text.to_s.strip.match?(/\A\p{L}\z/)

        # A run showing only one size of gap is one word, and is left joined.
        def letter_gap(words)
          gaps = words.each_cons(2).map { |left, right| (right['xMin'].to_f - left['xMax'].to_f).round(1) }.uniq.sort
          below, above = gaps.each_cons(2).max_by { |low, high| high - low }
          (below + above) / 2.0 if above && above >= [below, 0.1].max * LETTER_STEP
        end

        def word_separator(previous, word, spaced = nil)
          gap = word['xMin'].to_f - previous['xMax'].to_f
          return gap > spaced ? ' ' : '' if spaced

          gap < (previous['yMax'].to_f - previous['yMin'].to_f) * WORD_GAP_RATIO ? '' : ' '
        end

        # A bullet or a deep descender drags the line box down, so the baseline is the one most words share.
        def word_baseline(words)
          bottoms = words.map { |word| word['yMax'].to_f }.sort
          bottoms[bottoms.size / 2]
        end

        # Markers and other superscripts distort the line box, so size the line from its body words.
        def line_font_size(words, baseline)
          heights = words.reject { |word| superscript_marker?(word, baseline) }.map { |word| height_of(word) }.select(&:positive?).sort
          heights.empty? ? 0.0 : heights[heights.size / 2]
        end

        def superscript_marker?(word, baseline)
          word.text.match?(Markers::IDS_ONLY) && baseline - word['yMax'].to_f >= height_of(word) * SUPERSCRIPT_RISE
        end
      end
    end
  end
end
