require 'nokogiri'

module Audiobook
  module Parsers
    class Pdf < Base
      MAX_PAGES = ENV.fetch('MAX_PDF_PAGES', 2_000).to_i
      # How far above the baseline a marker sits, in its own heights, to be a footnote mark.
      SUPERSCRIPT_RISE = 0.2

      extend Words
      extend Tables
      extend Styles
      extend Info

      def self.extract_data(pdf_path, stl: nil, opts: nil, **_kwargs)
        info           = extract_pdfinfo(pdf_path)
        selected_pages = PageSelection.parse(opts&.pages)
        document, page_count = load_document(pdf_path, info.pages, selected_pages, opts)
        all_lines, image_pages = read_pages(document, pdf_path, page_count, stl)

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

      # The document and how many pages it has: the pages asked for, or else the whole of it.
      def self.load_document(pdf_path, page_count, selected_pages, opts)
        unless selected_pages
          document = extract_document(pdf_path, page_limit: MAX_PAGES + 1, lang: opts&.alang)
          raise ArgumentError, "PDF has too many pages (maximum #{MAX_PAGES})" if document.pages.size > MAX_PAGES

          return [document, document.pages.size]
        end

        raise ArgumentError, "too many selected pages (maximum #{MAX_PAGES})" if selected_pages.size > MAX_PAGES

        missing = selected_pages.reject { |page| page <= page_count }
        raise ArgumentError, "pages not found: #{missing.join(', ')}" if missing.any?

        [extract_document(pdf_path, page_limit: MAX_PAGES + 1, page_numbers: selected_pages, lang: opts&.alang), page_count]
      end

      # Text lines and, for a page with images, the image; a page can have both.
      def self.read_pages(document, pdf_path, page_count, stl)
        lines  = []
        images = []
        document.pages.each do |page|
          stl&.update "Analyzing document: page #{page.number}/#{page_count}"
          result = process_page(page, pdf_path)
          lines.concat(result.lines) if result.lines
          images << result.image if result.image
        end
        [lines, images]
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

      Parsed = Struct.new(:page, :height, :rows, :bands, :tables, :lines)
    end
  end
end
