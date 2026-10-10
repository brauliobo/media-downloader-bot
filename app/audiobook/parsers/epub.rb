require 'epub/parser'
require 'nokogiri'

module Audiobook
  module Parsers
    class Epub < Base
      ARCHIVE_LIMITS = {
        max_entries: 5_000, max_entry_bytes: 32.megabytes,
        max_total_bytes: 256.megabytes, max_ratio: 200
      }.freeze
      FONT_SIZES = {
        'h1' => 24, 'h2' => 22, 'h3' => 20, 'h4' => 18, 'h5' => 16, 'h6' => 14,
        'small' => 10, 'sup' => 10, 'sub' => 10
      }.freeze
      BLOCK_TAGS = %w[h1 h2 h3 h4 h5 h6 p li blockquote pre dt dd figcaption caption th td].freeze
      # A div carries no meaning of its own but does hold text, so it counts as a block and,
      # more to the point, as something a block must not contain to be the one that speaks.
      CONTAINERS = (BLOCK_TAGS + %w[div]).freeze

      # The page a line falls on: the one the last page break named, or one past it where the break names none.
      PageCursor = Struct.new(:current, :max) do
        def advance(number = nil)
          self.current = number && number > current ? number : current + 1
          self.max = [max, current].max
        end
      end

      def self.extract_data(epub_path, stl: nil, opts: nil, **_kwargs)
        Utils::Archive.validate_zip!(epub_path, **ARCHIVE_LIMITS)
        lines  = []
        cursor = PageCursor.new(1, 1)
        spine_idx = 0

        book = EPUB::Parser.parse(epub_path)
        book.each_page_on_spine do |spine_page|
          spine_idx += 1
          stl&.update "Analyzing document: spine item #{spine_idx}"
          read_spine_page(book, spine_page, cursor, lines)
        end

        stamp_blocks(lines)
        page_count = estimated_pages!(lines, [cursor.max, cursor.current, lines.map(&:page).max || 1].max, opts)

        SymMash.new(
          metadata: SymMash.new(page_count: page_count),
          content: SymMash.new(lines: lines, images: []),
          opts: opts
        )
      end

      # Note: CSS selectors that reference namespaced attributes like 'epub:type' are avoided because
      # Nokogiri's auto-generated XPath may be invalid without namespace bindings; page breaks are
      # found during the DOM traversal instead.
      def self.read_spine_page(book, spine_page, cursor, lines)
        doc = Nokogiri::HTML(spine_page.read)
        sheets = css_sheets(book, doc)
        changed = false
        (doc.at('body') || doc).css('*').each do |node|
          if (number = pagebreak_number_for(node))
            cursor.advance(number)
            changed = true
          else
            lines.concat(block_lines(node, sheets, cursor.current))
          end
        end
        # The page number advances between spine items, even if no markers were found
        cursor.advance unless changed
      end

      def self.block_lines(node, sheets, page)
        return [] unless container?(node)

        raw = block_of_interest?(node) ? extract_inline_text(node) : own_text(node)
        return [] if Text.normalize(raw).empty?

        style = CssStyle.for_node(node, sheets)
        # Hard breaks separate list items and verses; normalizing first would fuse them.
        raw.split(/\n+/).filter_map do |part|
          part = Text.normalize(part)
          next if part.empty?

          SymMash.new(
            text: part, font_size: style[:font_size] || effective_font_size_for(node),
            y: nil, page: page,
            bold: style[:bold] || bold?(node), italic: style[:italic] || italic?(node),
            alignment: style[:alignment] || alignment_for(node),
            section_level: heading_level(node),
            color: style[:color], font_name: style[:font_name]
          )
        end
      end

      # A book with few page breaks is paged by words (default ~300 per page), taking the larger
      # of the two counts. Answers the number of pages.
      def self.estimated_pages!(lines, page_count, opts)
        total_words = lines.sum { |line| line.text.to_s.split.size }
        desired = [page_count, [1, (total_words / words_per_page(opts).to_f).ceil].max].max
        return page_count unless desired > page_count && total_words.positive?

        words_per_page = total_words / desired.to_f
        accumulated = 0.0
        lines.each do |line|
          line.page = [1 + (accumulated / words_per_page).floor, desired].min
          # Count at least one word to avoid zero-length lines skewing distribution
          accumulated += [line.text.to_s.split.size, 1].max
        end
        desired
      end

      def self.extract_inline_text(node)
        return '' unless node
        return node.text if node.text?
        node.children.map { |c| c.name == 'br' ? "\n" : extract_inline_text(c) }.join
      end

      # Basic mapping of tag names to relative font sizes for grouping
      def self.effective_font_size_for(node)
        FONT_SIZES[node.name] || 12
      end

      def self.heading_level(node)
        node.name[1].to_i if node.name.match?(/\Ah[1-6]\z/)
      end

      def self.bold?(node)
        %w[h1 h2 h3 h4 h5 h6 b strong].include?(node.name) || node['style'].to_s.match?(/font-weight:\s*(bold|[6-9]00)/i)
      end

      def self.italic?(node)
        %w[i em].include?(node.name) || node['style'].to_s.match?(/font-style:\s*italic/i)
      end

      def self.alignment_for(node)
        align = node['align'].to_s.downcase.presence || node['style'].to_s[/text-align:\s*(left|right|center|justify)/i, 1]
        align&.downcase&.to_sym
      end

      def self.container?(node) = node.element? && CONTAINERS.include?(node.name)

      # Only the innermost block speaks its whole content: an exporter that wraps every paragraph
      # in two or three divs would otherwise read the same text once for each wrapper.
      def self.block_of_interest?(node) = container?(node) && node.css(*CONTAINERS).empty?

      # A wrapper still speaks whatever text is its own. An exporter sets a note's label beside
      # the block carrying the note, so skipping the wrapper altogether loses the label.
      def self.own_text(node)
        node.children.reject { |child| container?(child) }.map { |child| extract_inline_text(child) }.join
      end

      # Detect EPUB page break markers and return an integer page number if present
      def self.pagebreak_number_for(node)
        return nil unless node.element?
        attrs = [node['epub:type'], node['role'], node['class'], node['id'], node['title'], node.text].compact.join(' ').downcase
        return nil unless attrs =~ /(pagebreak|doc-pagebreak|page-break)/
        num = attrs[/\b(\d{1,4})\b/, 1]
        num && num.to_i > 0 ? num.to_i : nil
      end

      def self.css_sheets(book, doc)
        items = Array(book.manifest&.items)
        from_package = items.select { |item| item.media_type.to_s.include?('css') }
          .flat_map { |item| CssStyle.parse_sheet(item.read.to_s) }
        from_package + CssStyle.sheets_from(doc)
      end
    end
  end
end
