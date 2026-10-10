module Audiobook
  # The headings of a book as a tree: chapters, and under each the headings that follow it.
  module Outline
    module_function

    def build(pages)
      tree = []
      current = nil
      pages.each do |page|
        page.items.grep(Heading).each do |item|
          entry = heading_entry(item, page)
          if chapter?(item)
            current = entry.merge('headings' => [])
            tree << current
          elsif current
            current['headings'] << entry
          else
            tree << entry
          end
        end
      end
      tree.each { |entry| entry.delete('headings') if entry['headings']&.empty? }
      tree
    end

    def heading_entry(item, page)
      entry = { 'text' => item.text, 'page' => page.number }
      entry['role'] = item.role.to_s if item.role
      entry['level'] = item.level if item.is_a?(Section)
      entry['font_size'] = item.font_size if item.font_size
      entry['alignment'] = item.alignment.to_s if item.alignment
      entry['bold'] = item.bold unless item.bold.nil?
      entry['italic'] = item.italic unless item.italic.nil?
      entry['color'] = item.color if item.color
      entry['font_name'] = item.font_name if item.font_name
      entry
    end

    def chapter?(item)
      item.role.to_s == 'chapter' || (item.is_a?(Section) && item.level == 1 && item.role.to_s != 'title')
    end
  end
end
