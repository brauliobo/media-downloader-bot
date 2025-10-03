require 'epub/parser'
require 'nokogiri'
require_relative 'base'
require_relative '../text_helpers'
require_relative '../../ocr'

module Audiobook
  module Parsers
    class Epub < Base

      def self.extract_data(epub_path, stl: nil, opts: nil, **_kwargs)
        lines = []
        page_counter = 0

        book = EPUB::Parser.parse(epub_path)
        book.each_page_on_spine do |page|
          page_counter += 1
          stl&.update "Analyzing document: page #{page_counter}" if stl

          doc = Nokogiri::HTML(page.read)
          doc.css('p, h1, h2, h3, h4, h5, h6').each do |el|
            text = extract_inline_text(el).strip
            next if text.empty?
            lines << { text: text, font_size: nil, y: nil, page: page_counter }
          end
        end

        sample_paras = lines.first(10).map { |l| { text: l[:text] } }.reject { |p| p[:text].to_s.strip.empty? }
        lang = Ocr.detect_language(sample_paras) || 'en'
        
        {
          metadata: { language: lang, page_count: page_counter },
          content: { lines: lines, images: [] },
          opts: opts
        }
      end

      def self.extract_inline_text(node)
        return '' unless node
        return node.text if node.text?
        node.children.map { |child| extract_inline_text(child) }.join
      end
    end
  end
end
