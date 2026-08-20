require 'epub/parser'
require 'nokogiri'
require_relative 'base'
require_relative '../../text_helpers'
require_relative '../../utils/archive'
require_relative 'css_style'

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

      def self.extract_data(epub_path, stl: nil, opts: nil, **_kwargs)
        Utils::Archive.validate_zip!(epub_path, **ARCHIVE_LIMITS)
        lines = []
        current_page = 1
        max_page_seen = 1
        spine_idx = 0

        book = EPUB::Parser.parse(epub_path)
        book.each_page_on_spine do |spine_page|
          spine_idx += 1
          stl&.update "Analyzing document: spine item #{spine_idx}" if stl

          doc = Nokogiri::HTML(spine_page.read)
          body = (doc.at('body') || doc)
          sheets = css_sheets(book, doc)

          # Note: We avoid CSS selectors that reference namespaced attributes like 'epub:type'
          # because Nokogiri's auto-generated XPath may be invalid without namespace bindings.
          # Page-break detection is handled during the DOM traversal below.

          # Traverse elements in DOM order; update page counter on explicit pagebreak markers
          changed_in_spine = false
          body.css('*').each do |node|
            if pagebreak_number = pagebreak_number_for(node)
              # Prefer explicit number; otherwise just increment
              if pagebreak_number > current_page
                current_page = pagebreak_number
              else
                current_page += 1
              end
              max_page_seen = [max_page_seen, current_page].max
              changed_in_spine = true
              next
            end

            next unless block_of_interest?(node)

            text = TextHelpers.normalize_text(extract_inline_text(node))
            next if text.empty?

            style = CssStyle.for_node(node, sheets)
            # Split hard breaks into separate lines to help paragraph discovery
            text.split(/\n{2,}/).each do |part|
              part = part.strip
              next if part.empty?
              lines << SymMash.new(
                text: part, font_size: style[:font_size] || effective_font_size_for(node),
                y: nil, page: current_page,
                bold: style[:bold] || bold?(node), italic: style[:italic] || italic?(node),
                alignment: style[:alignment] || alignment_for(node),
                section_level: heading_level(node),
                color: style[:color], font_name: style[:font_name]
              )
            end
          end
          # Ensure page number advances between spine items, even if no markers were found
          current_page += 1 unless changed_in_spine
          max_page_seen = [max_page_seen, current_page].max
        end

        page_count = [max_page_seen, current_page, lines.map { |l| l.page }.max || 1].compact.max

        # Word-based pagination estimate (default ~300 words/page). Use the larger estimate.
        total_words = lines.sum { |l| l.text.to_s.split(/\s+/).reject(&:empty?).size }
        wpp = words_per_page(opts)
        est_pages = [1, (total_words / wpp.to_f).ceil].max
        desired_pages = [page_count, est_pages].max

        if desired_pages > page_count && total_words > 0
          words_per_page = total_words / desired_pages.to_f
          acc = 0.0
          lines.each do |l|
            page_num = 1 + (acc / words_per_page).floor
            l.page = [page_num, desired_pages].min
            # Count at least one word to avoid zero-length lines skewing distribution
            acc += [l.text.to_s.split(/\s+/).reject(&:empty?).size, 1].max
          end
          page_count = desired_pages
        end
        
        SymMash.new(
          metadata: SymMash.new(page_count: page_count),
          content: SymMash.new(lines: lines, images: []),
          opts: opts
        )
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

      # Decide if a node is a block we should extract text from
      def self.block_of_interest?(node)
        return false unless node.element?
        return true if BLOCK_TAGS.include?(node.name)
        node.name == 'div' && node.css(BLOCK_TAGS.join(',')).empty?
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
