require 'nokogiri'
require 'tmpdir'
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

        info           = extract_pdfinfo(pdf_path)
        page_count     = info.pages
        selected_pages = PageSelection.parse(opts&.pages)
        if selected_pages
          raise ArgumentError, "too many selected pages (maximum #{MAX_PAGES})" if selected_pages.size > MAX_PAGES

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

        first = document.pages.first
        cover = Cover.detect(pdf_path, page: first) if first

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
              text:       text,
              font_size:  y_max - y_min,
              y:          page_height - y_min,
              x:          line['xMin'].to_f,
              x_max:      line['xMax'].to_f,
              page_width: page['width'].to_f,
              y_min:      y_min,
              y_max:      y_max
            )
          end
          SymMash.new(
            number: first_page + index,
            width:  page['width'].to_f,
            height: page_height,
            lines:  lines
          )
        end
        apply_xml_styles(pages, pdf_path, first_page: first_page, last_page: last_page)
        pages
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

      BOLD_FONT   = /bold|black|heavy|semibold|demi|extrabold/i
      ITALIC_FONT = /italic|oblique/i

      def self.apply_xml_styles(pages, pdf_path, first_page:, last_page:)
        xml_pages = xml_style_pages(pdf_path, first_page: first_page, last_page: last_page)
        return if xml_pages.empty?

        pages.each do |page|
          fragments = xml_pages[page.number]
          next if fragments.blank?

          scale = fragments.first[:page_height].to_f.positive? ? page.height / fragments.first[:page_height].to_f : 1.0
          page.lines.each do |line|
            matches = fragments.select { |fragment| xml_match?(line, fragment, scale) }
            next if matches.empty?

            chars = matches.sum { |fragment| fragment[:text].length }
            next unless chars.positive?

            line.bold = matches.sum { |fragment| fragment[:bold] ? fragment[:text].length : 0 } >= chars / 2.0
            line.italic = matches.sum { |fragment| fragment[:italic] ? fragment[:text].length : 0 } >= chars / 2.0
            dominant = matches.max_by { |fragment| fragment[:text].length }
            line.font_name = dominant[:font_name].presence
            line.color = dominant[:color] if dominant[:color].present? && dominant[:color] !~ /\A#0+\z/i
          end
        end
      end

      def self.xml_style_pages(pdf_path, first_page:, last_page:)
        return {} unless pdftohtml_bin

        xml = pdftohtml_xml(pdf_path, first_page: first_page, last_page: last_page)
        return {} if xml.blank?

        fonts = {}
        document = Nokogiri::XML(xml) { |config| config.nonet }
        document.remove_namespaces!
        document.xpath('//page').each_with_object({}) do |page, pages|
          page.xpath('./fontspec').each do |font|
            fonts[font['id']] = {
              family: font['family'].to_s,
              color:  font['color'].to_s.presence
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
              text:        text,
              bold:        markup.match?(/<b[\s>]/i) || font[:family].match?(BOLD_FONT),
              italic:      markup.match?(/<i[\s>]/i) || font[:family].match?(ITALIC_FONT),
              font_name:   font[:family].presence,
              color:       font[:color],
              page_height: page['height'].to_f
            }
          end
        end
      end

      def self.pdftohtml_xml(pdf_path, first_page:, last_page:)
        Dir.mktmpdir('pdf-xml-') do |dir|
          output = File.join(dir, 'doc')
          _out, stderr, status = Sh.run [
            pdftohtml_bin, '-xml', '-i', '-q',
            '-f', first_page.to_s, '-l', last_page.to_s,
            pdf_path, output
          ]
          Sh.assert_success!('PDF style extraction failed', stderr, status: status)
          xml_path = File.exist?("#{output}.xml") ? "#{output}.xml" : Dir["#{dir}/*.xml"].first
          File.read(xml_path) if xml_path && File.exist?(xml_path)
        end
      end

      def self.pdftohtml_bin
        @pdftohtml_bin ||= %w[pdftohtml].find { system('which', _1, out: File::NULL, err: File::NULL) }
      end

      def self.xml_match?(line, fragment, scale)
        top = fragment[:top] * scale
        bottom = top + fragment[:height] * scale
        overlap = [line.y_max, bottom].min - [line.y_min, top].max
        return false if overlap < fragment[:height] * scale * 0.3

        xml_text = fragment[:text].downcase
        line_text = line.text.to_s.downcase
        line_text.include?(xml_text) || xml_text.include?(line_text[0, 24])
      end
    end
  end
end
