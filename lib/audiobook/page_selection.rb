module Audiobook
  class PageSelection
    MAX_SELECTED_PAGES = 10_000

    def self.parse(value)
      source = value.to_s.strip
      return if source.empty?

      pages = []
      source.split(',', -1).each do |token|
        selected = case token.strip
        when /\A(\d+)\z/
          [positive_page(Regexp.last_match(1), source)]
        when /\A(\d+)-(\d+)\z/
          first = positive_page(Regexp.last_match(1), source)
          last  = positive_page(Regexp.last_match(2), source)
          invalid!(source) if first > last || last - first + 1 > MAX_SELECTED_PAGES
          (first..last).to_a
        else
          invalid!(source)
        end
        invalid!(source) if pages.size + selected.size > MAX_SELECTED_PAGES
        pages.concat(selected)
      end

      pages.uniq.sort
    end

    def self.positive_page(value, source)
      value.to_i.then { |page| page.positive? ? page : invalid!(source) }
    end
    private_class_method :positive_page

    def self.invalid!(source)
      raise ArgumentError, "invalid pages option: #{source.inspect}"
    end
    private_class_method :invalid!
  end
end
