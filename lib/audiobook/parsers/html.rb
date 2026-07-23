require 'nokogiri'
require_relative 'base'
require_relative '../../text_helpers'

module Audiobook
  module Parsers
    class Html < Base
      MAX_BYTES = ENV.fetch('MAX_HTML_BYTES', 20 * 1024 * 1024).to_i
      BLOCK_SELECTOR = 'h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,dt,dd,figcaption,caption,th,td,center'.freeze
      EXCLUDED_SELECTOR = 'script,style,noscript,template,nav,form,button,svg'.freeze
      FONT_SIZES = {
        'h1' => 24, 'h2' => 22, 'h3' => 20, 'h4' => 18, 'h5' => 16, 'h6' => 14
      }.freeze
      WINDOWS_CONTROLS = {
        "\u0085" => '...', "\u0091" => "'", "\u0092" => "'",
        "\u0093" => '"', "\u0094" => '"', "\u0096" => '-', "\u0097" => '--'
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
        lines = if opts&.html_block_comments
          structured_lines(html, root, title_node)
        else
          selected_lines(root, selector)
        end
        page_count = paginate(lines, (opts&.wpp || 300).to_i)

        SymMash.new(
          metadata: SymMash.new(
            title:      normalize(title_node&.text),
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

          line(node_text(node), font_size(node))
        end
      end

      def self.structured_lines(html, root, title_node)
        lines = [line(normalize(title_node&.text), 24)].compact
        html.to_enum(:scan, /<!--\s*block\b[^>]*\btype=paragraph\b[^>]*-->(.*?)<!--\s*\/block\s*-->/mi).each do
          match = Regexp.last_match
          fragment = Nokogiri::HTML5.fragment(match[1])
          classes = html[[match.begin(0) - 300, 0].max...match.begin(0)].scan(/<p\b[^>]*class=["']?([^\s>"']+)/mi).last&.first
          lines << line(node_text(fragment), font_size_for_classes(classes))
        end
        root.css('.Para_Footnote').each { |node| lines << line(node_text(node), 10) }
        lines.compact
      end

      def self.read_html(path)
        raise ArgumentError, 'HTML document is too large' if File.size(path) > MAX_BYTES

        raw = File.binread(path)
        utf8 = raw.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        raw.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8)
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
        value = TextHelpers.normalize_text(text)
        WINDOWS_CONTROLS.each { |from, to| value.gsub!(from, to) }
        value.unicode_normalize(:nfc)
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

      def self.line(text, font_size)
        text = normalize(text)
        SymMash.new(text: text, font_size: font_size, y: nil, page: 1) unless text.empty?
      end

      def self.paginate(lines, words_per_page)
        words_per_page = 300 unless words_per_page.positive?
        words = 0
        lines.each do |line|
          line.page = 1 + words / words_per_page
          words += line.text.split.size
        end
        lines.last&.page || 1
      end
    end
  end
end
