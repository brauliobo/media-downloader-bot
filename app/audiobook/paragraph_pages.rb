module Audiobook
  # The older document shape: paragraphs, or only running text, numbered by page instead of lines.
  module ParagraphPages
    module_function

    def build(data, stl: nil)
      by_page = SymMash.new { |hash, page| hash[page] = [] }
      paragraphs(data, stl).each do |para|
        by_page[(para[:page_numbers] || [1]).first] << para[:text]
      end

      by_page.to_a.sort.map { |number, texts| Page.new(number, Paragraph.discover(texts)) }
    end

    def paragraphs(data, stl)
      paras = data.content&.paragraphs || []
      unless paras.empty?
        return paras.map do |para|
          SymMash.new(text: para['text'] || para[:text] || para.text, page_numbers: para['page_numbers'] || para[:page_numbers] || para.page_numbers || [1])
        end
      end

      stl&.update 'No paragraphs found, checking alternative text'
      alt = alternative_text(data)
      return [] unless alt&.strip&.length&.positive?

      [SymMash.new(text: alt, page_numbers: [1])]
    end

    def alternative_text(data)
      return data.text if data.text
      return data.content&.text if data.content&.text
      return pages_text(data) if data.content&.pages

      headers_and_footers(data) if data.metadata&.pages
    end

    def pages_text(data)
      text = data.content.pages.map { |page| page['text'] || page[:text] || page.text }.compact.join(' ')
      text.empty? ? nil : text
    end

    # A running head or foot is said once, where it first appears.
    def headers_and_footers(data)
      seen  = { header: Set.new, footer: Set.new }
      lines = data.metadata.pages.flat_map { |page| %i[header footer].map { |key| unseen(page, key, seen.fetch(key)) } }

      lines.compact.uniq.join(' ').then { |text| text.empty? ? nil : text }
    end

    def unseen(page, key, seen)
      text = SymMash.wrap(page)[key]&.strip
      return unless text&.length&.positive?

      (text unless seen.include?(text)).tap { seen << text }
    end
  end
end
