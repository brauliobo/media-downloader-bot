require 'epub/parser'
require 'nokogiri'
require_relative 'base'
require_relative '../../text_helpers'

module Audiobook
  module Parsers
    class Epub < Base
      FONT_SIZES = {
        'h1' => 24, 'h2' => 22, 'h3' => 20, 'h4' => 18, 'h5' => 16, 'h6' => 14,
        'small' => 10, 'sup' => 10, 'sub' => 10
      }.freeze
      BLOCK_TAGS = %w[h1 h2 h3 h4 h5 h6 p li blockquote pre dt dd figcaption caption th td].freeze

      def self.extract_data(epub_path, stl: nil, opts: nil, **_kwargs)
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

            font = effective_font_size_for(node)
            # Split hard breaks into separate lines to help paragraph discovery
            text.split(/\n{2,}/).each do |part|
              part = part.strip
              next if part.empty?
              lines << SymMash.new('text' => part, 'font_size' => font, 'y' => nil, 'page' => current_page)
            end
          end
          # Ensure page number advances between spine items, even if no markers were found
          current_page += 1 unless changed_in_spine
          max_page_seen = [max_page_seen, current_page].max
        end

        page_count = [max_page_seen, current_page, lines.map { |l| l.page }.max || 1].compact.max

        # Word-based pagination estimate (default ~300 words/page). Use the larger estimate.
        total_words = lines.sum { |l| l.text.to_s.split(/\s+/).reject(&:empty?).size }
        wpp = (opts&.wpp || 300).to_i
        wpp = 300 if wpp <= 0
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
    end
  end
end
