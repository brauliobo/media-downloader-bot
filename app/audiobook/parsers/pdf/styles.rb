module Audiobook
  module Parsers
    class Pdf
      # Bold, italic and size come from the XML pdftohtml writes, matched back to the lines already read.
      module Styles
        XML_CHAR  = /[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/
        BOLD_FONT   = /bold|black|heavy|semibold|demi|extrabold/i

        ITALIC_FONT = /italic|oblique/i

        # The text box of a line stretches with tall glyphs, so prefer the nominal font size when available.
        def apply_xml_styles(pages, pdf_path, first_page:, last_page:)
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

        def page_scale(fragment, page)
          SymMash.new(
            x: fragment[:page_width].to_f.positive?  ? page.width / fragment[:page_width].to_f   : 1.0,
            y: fragment[:page_height].to_f.positive? ? page.height / fragment[:page_height].to_f : 1.0,
          )
        end

        def apply_line_style(line, matches, scale)
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
        def tag_superscript_markers(text, matches, dominant)
          matches.reduce(text) do |result, fragment|
            next result unless fragment[:text].match?(Markers::IDS_ONLY)
            next result unless dominant[:top] - fragment[:top] >= fragment[:height] * SUPERSCRIPT_RISE

            result.sub(/(?<=[^\d\s])#{fragment[:text]}(?=\s|\z)/, Markers.wrap(fragment[:text]))
          end
        end

        # Lines without a style fragment keep their box height, rescaled to the nominal range.
        def normalize_unstyled_sizes(lines, ratios)
          return if lines.empty? || ratios.empty?

          median = ratios.sort[ratios.size / 2]
          lines.each do |line|
            line.font_size = (line.font_size.to_f * median).round(2) if line.font_size.to_f.positive?
          end
        end

        def xml_style_pages(pdf_path, first_page:, last_page:)
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

        def pdftohtml_xml(pdf_path, first_page:, last_page:)
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

        def pdftohtml_bin
          @pdftohtml_bin ||= %w[pdftohtml].find { Sh.which?(_1) }
        end

        def sanitize_xml(text) = text.to_s.gsub(XML_CHAR, '')

        def xml_match?(line, fragment, scale)
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
end
