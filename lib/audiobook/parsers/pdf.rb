require 'nokogiri'
require_relative 'base'
require_relative '../cover'
require_relative '../page_selection'
require_relative '../../utils/sh'

module Audiobook
  module Parsers
    class Pdf < Base
      MAX_PAGES = ENV.fetch('MAX_PDF_PAGES', 2_000).to_i

      def self.extract_data(pdf_path, stl: nil, opts: nil, **_kwargs)
        all_lines = []
        image_pages = []

        selected_pages = PageSelection.parse(opts&.pages)
        if selected_pages
          raise ArgumentError, "too many selected pages (maximum #{MAX_PAGES})" if selected_pages.size > MAX_PAGES

          page_count = extract_page_count(pdf_path)
          missing = selected_pages.reject { |page| page <= page_count }
          raise ArgumentError, "pages not found: #{missing.join(', ')}" if missing.any?

          document = extract_document(pdf_path, page_limit: MAX_PAGES + 1, page_numbers: selected_pages)
        else
          document   = extract_document(pdf_path, page_limit: MAX_PAGES + 1)
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

        cover = Cover.detect(pdf_path, page: document.pages.first) if document.pages.any?

        SymMash.new(
          metadata: SymMash.new(
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

        result = SymMash.new
        result.lines = page_lines if page_lines.any?
        if page_lines.empty?
          result.image = SymMash.new(image: true, page: page_num, path: "#{pdf_path}#page=#{page_num}")
        end

        result
      end

      def self.extract_document(pdf_path, page_limit:, page_numbers: nil)
        ranges = page_numbers ? consecutive_ranges(page_numbers) : [[1, page_limit]]
        pages = ranges.flat_map do |first_page, last_page|
          extract_document_range(pdf_path, first_page: first_page, last_page: last_page)
        end
        SymMash.new(pages: pages)
      end

      def self.extract_document_range(pdf_path, first_page:, last_page:)
        output, stderr, status = Sh.run [
          'pdftotext', '-f', first_page.to_s, '-l', last_page.to_s,
          '-bbox-layout', '-enc', 'UTF-8', pdf_path, '-'
        ]
        Sh.assert_success!('PDF text extraction failed', stderr, status: status)

        document = Nokogiri::XML(output) { |config| config.strict.nonet }
        document.remove_namespaces!
        pages = document.xpath('//page').each_with_index.map do |page, index|
          page_height = page['height'].to_f
          lines       = page.xpath('.//line').filter_map do |line|
            words = line.xpath('./word')
            text  = line_text(words)
            next if text.empty?

            y_min = line['yMin'].to_f
            y_max = line['yMax'].to_f
            SymMash.new(
              text:      text,
              font_size: y_max - y_min,
              y:         page_height - y_min,
              x:         line['xMin'].to_f,
              y_min:     y_min,
              y_max:     y_max
            )
          end
          SymMash.new(
            number: first_page + index,
            width:  page['width'].to_f,
            height: page_height,
            lines:  lines
          )
        end
        pages
      end

      def self.extract_page_count(pdf_path)
        output, stderr, status = Sh.run ['pdfinfo', pdf_path]
        Sh.assert_success!('PDF page count failed', stderr, status: status)
        count = output[/^Pages:\s+(\d+)$/i, 1]&.to_i
        raise 'PDF page count missing' unless count&.positive?

        count
      end

      def self.consecutive_ranges(page_numbers)
        page_numbers.slice_when { |left, right| right != left + 1 }.map { |range| [range.first, range.last] }
      end

      def self.line_text(words)
        baseline = words.map { |word| word['yMax'].to_f }.max
        words.each_with_index.map do |word, index|
          separator = index.positive? && !superscript_marker?(word, baseline) ? ' ' : ''
          "#{separator}#{word.text}"
        end.join.strip
      end

      def self.superscript_marker?(word, baseline)
        word.text.match?(/\A\d{1,3}\z/) && word['yMax'].to_f < baseline - 1.0
      end
    end
  end
end
