require 'nokogiri'

module Audiobook
  module Parsers
    class Pdf < Base
      MAX_PAGES = ENV.fetch('MAX_PDF_PAGES', 2_000).to_i
      XML_CHAR  = /[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/

      def self.extract_data(pdf_path, stl: nil, opts: nil, **_kwargs)
        all_lines = []
        image_pages = []

        info           = extract_pdfinfo(pdf_path)
        page_count     = info.pages
        selected_pages = PageSelection.parse(opts&.pages)
        if selected_pages
          raise ArgumentError, "too many selected pages (maximum #{MAX_PAGES})" if selected_pages.size > MAX_PAGES

          missing = selected_pages.reject { |page| page <= page_count }
          raise ArgumentError, "pages not found: #{missing.join(', ')}" if missing.any?

          document = extract_document(pdf_path, page_limit: MAX_PAGES + 1, page_numbers: selected_pages, lang: opts&.alang)
        else
          document   = extract_document(pdf_path, page_limit: MAX_PAGES + 1, lang: opts&.alang)
          page_count = document.pages.size
          raise ArgumentError, "PDF has too many pages (maximum #{MAX_PAGES})" if page_count > MAX_PAGES
        end

        document.pages.each do |page|
          stl&.update "Analyzing document: page #{page.number}/#{page_count}" if stl
          res = process_page(page, pdf_path)
          if res.lines
            all_lines.concat(res.lines)
          end
          # Add image if page has images (can coexist with text)
          if res.image
            image_pages << res.image
          end
        end

        first = document.pages.first
        cover = Cover.from_page(pdf_path, first) if first

        SymMash.new(
          metadata: SymMash.new(
            title:          info.title.presence || File.basename(pdf_path, '.*'),
            pdf_author:     info.author,
            source_name:    File.basename(pdf_path, '.*'),
            source_path:    pdf_path,
            page_width:     first&.width,
            page_height:    first&.height,
            cover:          cover,
            has_ocr_pages:  image_pages.any?,
            page_count:     page_count,
            selected_pages: selected_pages,
          ),
          content: SymMash.new(lines: all_lines, images: image_pages),
          opts: opts
        )
      end

      def self.process_page(page, pdf_path)
        page_num   = page.number
        page_lines = page.lines.map { |line| SymMash.new(line.to_h.merge(page: page_num)) }

        page_lines.each_with_index do |line, idx|
          line.top_spacing    = line.y_min - page_lines[idx - 1].y_max if idx.positive?
          line.bottom_spacing = page_lines[idx + 1].y_min - line.y_max if idx < page_lines.size - 1
        end
        normalize_bullets(page_lines)

        result = SymMash.new
        result.lines = page_lines if page_lines.any?
        if page_lines.empty? || scanned_page?(pdf_path, page, page_lines)
          result.image = SymMash.new(image: true, page: page_num, path: "#{pdf_path}#page=#{page_num}")
        end

        result
      end

      # A bullet the text layer could not map comes out as a lone "0" or "o" opening each item;
      # the items give it away by repeating down one margin.
      BULLET_LOOKALIKE = /\A[0oO°](?=\s+\p{Lu})/u
      BULLET_MARGIN    = 2.0

      def self.normalize_bullets(page_lines)
        candidates = page_lines.select { |line| line.text.match?(BULLET_LOOKALIKE) }
        return if candidates.size < 2

        margin = candidates.map { |line| line.x.to_f }.tally.max_by { |_, count| count }.first
        candidates.each do |line|
          line.text = line.text.sub(BULLET_LOOKALIKE, '•') if (line.x.to_f - margin).abs <= BULLET_MARGIN
        end
      end

      # A page whose text layer only holds a header/footer keeps its content inside a dominant image.
      TEXT_LAYER_CHARS  = 120
      MIN_SCANNED_AREA  = 0.25

      def self.scanned_page?(pdf_path, page, page_lines)
        page_lines.sum { |line| line.text.length } <= TEXT_LAYER_CHARS && dominant_image?(pdf_path, page)
      end

      def self.dominant_image?(pdf_path, page)
        output, stderr, status = Sh.run [
          'pdfimages', '-f', page.number.to_s, '-l', page.number.to_s, '-list', pdf_path
        ]
        Sh.assert_success!('PDF image list failed', stderr, status: status)
        output.lines.filter_map { |line| Cover.image_metrics(line, page) }
          .any? { |metrics| metrics.area_coverage >= MIN_SCANNED_AREA }
      end

      def self.extract_document(pdf_path, page_limit:, page_numbers: nil, lang: nil)
        ranges = page_numbers ? consecutive_ranges(page_numbers) : [[1, page_limit]]
        pages = ranges.flat_map do |first_page, last_page|
          extract_document_range(pdf_path, first_page: first_page, last_page: last_page, lang: lang)
        end
        SymMash.new(pages: pages)
      end

      def self.extract_document_range(pdf_path, first_page:, last_page:, lang: nil)
        output, stderr, status = Sh.run [
          'pdftotext', '-f', first_page.to_s, '-l', last_page.to_s,
          '-bbox-layout', '-enc', 'UTF-8', pdf_path, '-'
        ]
        Sh.assert_success!('PDF text extraction failed', stderr, status: status)

        document = Nokogiri::XML(sanitize_xml(output)) { |config| config.strict.nonet }
        document.remove_namespaces!
        pages = fold_tables(document.xpath('//page').map { |page| tabled_page(page) }, lang)
          .each_with_index.map do |parsed, index|
            SymMash.new(
              number: first_page + index,
              width:  parsed.page['width'].to_f,
              height: parsed.page['height'].to_f,
              lines:  parsed.lines
            )
          end
        apply_xml_styles(pages, pdf_path, first_page: first_page, last_page: last_page)
        pages
      end

      def self.line_of(words, page)
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

      Parsed = Struct.new(:page, :height, :rows, :bands, :tables, :lines)

      def self.tabled_page(page)
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
      def self.fold_tables(parsed, lang)
        long = long_tables(parsed)
        parsed.each_with_index do |page, index|
          page.bands.each_with_index.reverse_each do |band, at|
            page.lines = fold_band(page.lines, page.rows[band], page.tables[at], page.height, lang, long[index])
          end
        end
      end

      # A page given over to a table, and the number of them a table may run to before it is a
      # dataset rather than a passage.
      TABLE_PAGE  = 0.6
      TABLE_PAGES = 2

      # The row count to announce, per page, for a table that runs past more pages than a
      # listener will sit through: the first page of the run carries it and the rest read empty.
      def self.long_tables(parsed)
        tabled = parsed.map { |page| page.tables.sum(&:size) if page.bands.sum(&:size) >= page.rows.size * TABLE_PAGE }
        tabled.each_index.slice_when { |above, below| tabled[above].nil? || tabled[below].nil? }
          .each_with_object({}) do |run, long|
            next if tabled[run.first].nil? || run.size <= TABLE_PAGES

            total = run.sum { |index| tabled[index] }
            run.each_with_index { |index, at| long[index] = at.zero? ? total : 0 }
          end
      end

      def self.fold_band(lines, band, table, height, lang, long)
        inside = lines.select { |line| line.y_min.to_f.between?(band.first.first - 1, band.last.first + height) }
        return lines if inside.empty?

        spoken = Table.spoken(table, band.first.first, lang, long).map { |y, text| table_line(inside.first, y, height, text) }
        lines.flat_map { |line| line.equal?(inside.first) ? spoken : (inside.any? { |row| row.equal?(line) } ? [] : [line]) }
      end

      def self.table_line(model, y, height, text)
        model.merge(text: text, y_min: y, y_max: y + height, y: model.page_height.to_f - y - height)
      end

      def self.median_height(words)
        heights = words.map { |word| height_of(word) }.sort
        heights[heights.size / 2]
      end

      def self.extract_pdfinfo(pdf_path)
        output, stderr, status = Sh.run ['pdfinfo', pdf_path]
        Sh.assert_success!('PDF page count failed', stderr, status: status)
        count = output[/^Pages:\s+(\d+)$/i, 1]&.to_i
        raise 'PDF page count missing' unless count&.positive?

        SymMash.new(pages: count, title: pdfinfo_field(output, 'Title'), author: pdfinfo_field(output, 'Author'))
      end

      def self.pdfinfo_field(output, label)
        value = output[/^#{Regexp.escape(label)}:\s+(.+)$/i, 1]&.strip
        value if value.present? && value != '-'
      end

      def self.extract_page_count(pdf_path)
        extract_pdfinfo(pdf_path).pages
      end

      def self.consecutive_ranges(page_numbers)
        page_numbers.slice_when { |left, right| right != left + 1 }.map { |range| [range.first, range.last] }
      end

      # Words closer than this fraction of their height belong to the same word (small caps runs).
      WORD_GAP_RATIO     = 0.05
      BASELINE_TOLERANCE = 0.5
      # Fragments of one justified line sit within a couple of spaces; a contents entry is further from its folio.
      ADJACENT_GAP_RATIO = 1.75

      # Justified text and page-number columns come out as several lines on one baseline, and a
      # re-rendered PDF puts each fragment in its own block, so rejoin what sits side by side.
      def self.baseline_runs(lines)
        slices = lines.group_by(&:parent).values.flat_map { |block| baseline_slices(block) }
        adopt_bullet_runs(fold_adjacent_runs(slices)).map { |words| words.sort_by { |word| word['xMin'].to_f } }
      end

      def self.fold_adjacent_runs(slices)
        slices.each_with_object([]) do |words, runs|
          side_by_side?(runs.last, words) ? runs.last.concat(words) : runs << words
        end
      end

      # A bullet column is often set as one block of its own, so a bullet never neighbours the entry it opens.
      def self.adopt_bullet_runs(runs)
        runs.reject do |words|
          next false unless bullet_run?(words)

          entry = runs.find { |other| !other.equal?(words) && side_by_side?(words, other) }
          entry&.concat(words)
        end
      end

      def self.bullet_run?(words)
        text = words.map(&:text).join.strip
        text.present? && ListMark::BULLETS.include?(text)
      end

      def self.baseline_slices(block)
        block.slice_when { |prev, line| !same_baseline?(prev, line) }
          .map { |slice| slice.flat_map { |line| line.xpath('./word').to_a } }
      end

      def self.side_by_side?(run, words)
        return false if run.blank? || words.blank?

        left, right = run.max_by { |word| word['xMax'].to_f }, words.min_by { |word| word['xMin'].to_f }
        gap = right['xMin'].to_f - left['xMax'].to_f
        same_baseline?(left, right) && gap >= 0 && gap < [height_of(left), height_of(right)].max * ADJACENT_GAP_RATIO
      end

      def self.same_baseline?(above, below)
        (below['yMin'].to_f - above['yMin'].to_f).abs <= [height_of(above), height_of(below)].min * BASELINE_TOLERANCE
      end

      def self.height_of(node) = node['yMax'].to_f - node['yMin'].to_f

      def self.line_text(words, baseline = word_baseline(words))
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

      # Letter-spaced type, and the small capitals a re-rendered PDF splits the same way, reach
      # the text layer one letter to a word and are read out letter by letter. A run of them has
      # gaps of two sizes and no others: between two letters of a word and between two words,
      # and the widest step between the two is where the words divide. A line may letter-space a
      # phrase and set the rest of itself normally, so the runs are read one at a time.
      LETTER_RUN  = 3
      LETTER_STEP = 1.5

      def self.letter_gaps(words)
        words.each_index.select { |at| single?(words[at]) }
          .slice_when { |above, below| below > above + 1 }
          .select { |run| run.count { |at| letter?(words[at]) } >= LETTER_RUN }
          .each_with_object({}) do |run, gaps|
            gap = letter_gap(words[run.first..run.last])
            run.each { |at| gaps[at] = gap } if gap
          end
      end

      # A digit or a mark set among the letters belongs to the run; letters alone declare one.
      def self.single?(word) = word.text.to_s.strip.length == 1
      def self.letter?(word) = word.text.to_s.strip.match?(/\A\p{L}\z/)

      # A run showing only one size of gap is one word, and is left joined.
      def self.letter_gap(words)
        gaps = words.each_cons(2).map { |left, right| (right['xMin'].to_f - left['xMax'].to_f).round(1) }.uniq.sort
        below, above = gaps.each_cons(2).max_by { |low, high| high - low }
        (below + above) / 2.0 if above && above >= [below, 0.1].max * LETTER_STEP
      end

      def self.word_separator(previous, word, spaced = nil)
        gap = word['xMin'].to_f - previous['xMax'].to_f
        return gap > spaced ? ' ' : '' if spaced

        gap < (previous['yMax'].to_f - previous['yMin'].to_f) * WORD_GAP_RATIO ? '' : ' '
      end

      # A bullet or a deep descender drags the line box down, so the baseline is the one most words share.
      def self.word_baseline(words)
        bottoms = words.map { |word| word['yMax'].to_f }.sort
        bottoms[bottoms.size / 2]
      end

      # Markers and other superscripts distort the line box, so size the line from its body words.
      def self.line_font_size(words, baseline)
        heights = words.reject { |word| superscript_marker?(word, baseline) }.map { |word| height_of(word) }.select(&:positive?).sort
        heights.empty? ? 0.0 : heights[heights.size / 2]
      end

      SUPERSCRIPT_RISE = 0.2

      def self.superscript_marker?(word, baseline)
        word.text.match?(Markers::IDS_ONLY) && baseline - word['yMax'].to_f >= height_of(word) * SUPERSCRIPT_RISE
      end

      BOLD_FONT   = /bold|black|heavy|semibold|demi|extrabold/i
      ITALIC_FONT = /italic|oblique/i

      # The text box of a line stretches with tall glyphs, so prefer the nominal font size when available.
      def self.apply_xml_styles(pages, pdf_path, first_page:, last_page:)
        xml_pages = xml_style_pages(pdf_path, first_page: first_page, last_page: last_page)
        return if xml_pages.empty?

        ratios   = []
        unstyled = []
        pages.each do |page|
          fragments = xml_pages[page.number]
          next unstyled.concat(page.lines) if fragments.blank?

          scale = page_scale(fragments.first, page)
          page.lines.each do |line|
            matches = fragments.select { |fragment| xml_match?(line, fragment, scale) }
            ratio   = apply_line_style(line, matches, scale) if matches.any?
            ratio ? ratios << ratio : unstyled << line
          end
        end
        normalize_unstyled_sizes(unstyled, ratios)
      end

      def self.page_scale(fragment, page)
        SymMash.new(
          x: fragment[:page_width].to_f.positive?  ? page.width / fragment[:page_width].to_f   : 1.0,
          y: fragment[:page_height].to_f.positive? ? page.height / fragment[:page_height].to_f : 1.0,
        )
      end

      def self.apply_line_style(line, matches, scale)
        chars = matches.sum { |fragment| fragment[:text].length }
        return if chars.zero?

        line.bold   = matches.sum { |fragment| fragment[:bold] ? fragment[:text].length : 0 } >= chars / 2.0
        line.italic = matches.sum { |fragment| fragment[:italic] ? fragment[:text].length : 0 } >= chars / 2.0
        dominant    = matches.max_by { |fragment| fragment[:text].length }
        line.text   = tag_superscript_markers(line.text, matches, dominant)
        line.font_name = dominant[:font_name].presence
        line.color = dominant[:color] if dominant[:color].present? && dominant[:color] !~ /\A#0+\z/i

        nominal = dominant[:size].to_f * scale.y
        return unless nominal.positive? && line.font_size.to_f.positive?

        ratio = nominal / line.font_size.to_f
        line.font_size = nominal.round(2)
        ratio
      end

      # Text extraction can glue a raised marker onto the number before it; the style pass still sees them apart.
      def self.tag_superscript_markers(text, matches, dominant)
        matches.reduce(text) do |result, fragment|
          next result unless fragment[:text].match?(Markers::IDS_ONLY)
          next result unless dominant[:top] - fragment[:top] >= fragment[:height] * SUPERSCRIPT_RISE

          result.sub(/(?<=[^\d\s])#{fragment[:text]}(?=\s|\z)/, Markers.wrap(fragment[:text]))
        end
      end

      # Lines without a style fragment keep their box height, rescaled to the nominal range.
      def self.normalize_unstyled_sizes(lines, ratios)
        return if lines.empty? || ratios.empty?

        median = ratios.sort[ratios.size / 2]
        lines.each do |line|
          line.font_size = (line.font_size.to_f * median).round(2) if line.font_size.to_f.positive?
        end
      end

      def self.xml_style_pages(pdf_path, first_page:, last_page:)
        return {} unless pdftohtml_bin

        xml = pdftohtml_xml(pdf_path, first_page: first_page, last_page: last_page)
        return {} if xml.blank?

        fonts = {}
        document = Nokogiri::XML(sanitize_xml(xml)) { |config| config.nonet }
        document.remove_namespaces!
        document.xpath('//page').each_with_object({}) do |page, pages|
          page.xpath('./fontspec').each do |font|
            fonts[font['id']] = {
              family: font['family'].to_s,
              color:  font['color'].to_s.presence,
              size:   font['size'].to_f
            }
          end
          pages[page['number'].to_i] = page.xpath('./text').filter_map do |node|
            text = node.text.to_s.gsub(/\s+/, ' ').strip
            next if text.empty?

            font = fonts[node['font']] || {}
            markup = node.inner_html
            {
              top:         node['top'].to_f,
              height:      node['height'].to_f,
              left:        node['left'].to_f,
              width:       node['width'].to_f,
              text:        text,
              bold:        markup.match?(/<b[\s>]/i) || font[:family].to_s.match?(BOLD_FONT),
              italic:      markup.match?(/<i[\s>]/i) || font[:family].to_s.match?(ITALIC_FONT),
              font_name:   font[:family].presence,
              color:       font[:color],
              size:        font[:size],
              page_height: page['height'].to_f,
              page_width:  page['width'].to_f
            }
          end
        end
      end

      def self.pdftohtml_xml(pdf_path, first_page:, last_page:)
        Utils::Tmp.dir('pdf-xml-') do |dir|
          output = File.join(dir, 'doc')
          _out, stderr, status = Sh.run [
            pdftohtml_bin, '-xml', '-i', '-q', '-nodrm',
            '-f', first_page.to_s, '-l', last_page.to_s,
            pdf_path, output
          ]
          Sh.assert_success!('PDF style extraction failed', stderr, status: status)
          xml_path = File.exist?("#{output}.xml") ? "#{output}.xml" : Dir["#{dir}/*.xml"].first
          File.read(xml_path) if xml_path && File.exist?(xml_path)
        end
      end

      def self.pdftohtml_bin
        @pdftohtml_bin ||= %w[pdftohtml].find { Sh.which?(_1) }
      end

      def self.sanitize_xml(text) = text.to_s.gsub(XML_CHAR, '')

      def self.xml_match?(line, fragment, scale)
        top     = fragment[:top] * scale.y
        bottom  = top + fragment[:height] * scale.y
        height  = [line.y_max - line.y_min, bottom - top].min
        return false if height <= 0 || [line.y_max, bottom].min - [line.y_min, top].max < height * 0.5

        left  = fragment[:left] * scale.x
        width = fragment[:width] * scale.x
        return false unless width.positive?

        [line.x_max, left + width].min - [line.x, left].max >= width * 0.5
      end
    end
  end
end
