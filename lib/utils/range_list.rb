module Utils
  class RangeList
    Span = Data.define(:first, :last)

    def self.parse(value, option:, allow_single: true, &parse_value)
      source = value.to_s.strip
      return if source.empty?

      source.split(',', -1).map do |token|
        values = token.strip.split('-', -1)
        invalid!(option, source) unless values.size == 2 || allow_single && values.size == 1

        first = parse_endpoint(values.first, option, source, &parse_value)
        last  = values.size == 2 ? parse_endpoint(values.last, option, source, &parse_value) : first
        invalid!(option, source) if first > last

        Span.new(first: first, last: last)
      end
    end

    def self.parse_endpoint(value, option, source)
      yield value
    rescue ArgumentError, TypeError
      invalid!(option, source)
    end
    private_class_method :parse_endpoint

    def self.invalid!(option, source)
      raise ArgumentError, "invalid #{option} option: #{source.inspect}"
    end
    private_class_method :invalid!
  end
end
