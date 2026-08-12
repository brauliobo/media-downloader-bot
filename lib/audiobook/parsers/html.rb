require 'nokogiri'
require_relative 'base'

module Audiobook
  module Parsers
    class Html < Base
      MAX_BYTES = ENV.fetch('MAX_HTML_BYTES', 20 * 1024 * 1024).to_i
      BLOCK_SELECTOR = 'h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,dt,dd,figcaption,caption,th,td,center'.freeze
      EXCLUDED_SELECTOR = 'script,style,noscript,template,nav,form,button,svg'.freeze
      FONT_SIZES = {
        'h1' => 24, 'h2' => 22, 'h3' => 20, 'h4' => 18, 'h5' => 16, 'h6' => 14
      }.freeze

      def self.extract_data(path, stl: nil, opts: nil, **_kwargs)
        html     = read_html(path)
        document = Nokogiri::HTML5.parse(html)
        parser_opts = SymMash.new(opts || {})
        parser_opts.includeall = true
        root     = document.at('main,article,body') || document
        root.css(EXCLUDED_SELECTOR).remove
        selector = opts&.html_content_selector.to_s.presence || BLOCK_SELECTOR
        title_node = document.at(opts&.html_title_selector.to_s.presence || 'title,h1')
        title = normalize(opts&.html_title.presence || title_node&.text)
        lines = if opts&.html_block_comments
          structured_lines(html, root, title)
        else
          selected_lines(root, selector)
        end
        page_count = paginate(lines, words_per_page(opts))

        SymMash.new(
          metadata: SymMash.new(
            title:      title,
            language:   opts&.html_language,
            page_count: page_count
          ).compact,
          content: SymMash.new(lines: lines, images: []),
          opts: parser_opts
        )
      end

      def self.selected_lines(root, selector)
        root.css(selector).filter_map do |node|
          next if node.ancestors.any? { |ancestor| ancestor.element? && ancestor.matches?(selector) }

          line(
            node_text(node),
            font_size(node),
            section_level: section_level(node),
            language: node_language(node)
          )
        end
      end

      def self.structured_lines(html, root, title)
        lines = [line(title, 24)].compact
        html.to_enum(:scan, /<!--\s*block\b[^>]*\btype=paragraph\b[^>]*-->(.*?)<!--\s*\/block\s*-->/mi).each do
          match = Regexp.last_match
          fragment = Nokogiri::HTML5.fragment(match[1])
          opening_tag = html[[match.begin(0) - 300, 0].max...match.begin(0)].scan(/<p\b[^>]*>/mi).last
          paragraph = Nokogiri::HTML5.fragment(opening_tag.to_s).at_css('p')
          classes = paragraph&.[]('class')
          lines << line(
            node_text(fragment),
            font_size_for_classes(classes),
            section_level: section_level_for_classes(classes),
            language: paragraph&.[]('lang')
          )
        end
        root.css('.Para_Footnote').each { |node| lines << line(node_text(node), 10) }
        lines.compact
      end

      def self.read_html(path)
        raise ArgumentError, 'HTML document is too large' if File.size(path) > MAX_BYTES

        read_text(path, max_bytes: MAX_BYTES)
      end

      def self.node_text(node)
        copy = node.dup
        footnote = copy.element? && copy['class'].to_s.split.include?('Para_Footnote')
        copy.css('sup,script,style,noscript,template').remove
        copy.css('br').each { |br| br.replace("\n") }
        text = normalize(copy.text)
        return text unless footnote

        id = text[/\A\(?\s*(\d+)\s*\)?/, 1]
        text = text.sub(/\A\(?\s*\d+\s*\)?\s*/, '') if id
        id ? "Footnote #{id}. #{text}" : text
      end

      def self.normalize(text)
        normalize_plain_text(text)
      end

      def self.font_size(node)
        return FONT_SIZES[node.name] if FONT_SIZES.key?(node.name)

        classes = node['class'].to_s
        return 20 if classes.match?(/Major_Heading|book_chapter_title/i)
        return 18 if classes.match?(/Minor_Heading/i)
        return 10 if classes.match?(/Footnote/i)

        12
      end

      def self.font_size_for_classes(classes)
        return 20 if classes.to_s.match?(/Major_Heading/i)
        return 18 if classes.to_s.match?(/Minor_Heading/i)

        12
      end

      def self.section_level(node)
        section_level_for_classes(node['class'])
      end

      def self.section_level_for_classes(classes)
        return 1 if classes.to_s.match?(/Major_Heading/i)
        return 2 if classes.to_s.match?(/Minor_Heading/i)
      end

      def self.node_language(node)
        [node, *node.ancestors].filter_map { |element| element['lang'].to_s.strip.presence }.first
      end

    end
  end
end
