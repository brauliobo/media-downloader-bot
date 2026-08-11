require_relative '../utils/range_list'

module Audiobook
  class PageSelection
    MAX_SELECTED_PAGES = 10_000

    def self.parse(value)
      ranges = Utils::RangeList.parse(value, option: :pages) { |part| positive_page(part) }
      return unless ranges

      pages = []
      ranges.each do |range|
        count = range.last - range.first + 1
        invalid!(value) if count > MAX_SELECTED_PAGES || pages.size + count > MAX_SELECTED_PAGES
        pages.concat((range.first..range.last).to_a)
      end

      pages.uniq.sort
    end

    def self.positive_page(value)
      Integer(value, 10).then { |page| page.positive? ? page : raise(ArgumentError) }
    end
    private_class_method :positive_page

    def self.invalid!(source)
      raise ArgumentError, "invalid pages option: #{source.inspect}"
    end
    private_class_method :invalid!
  end
end
