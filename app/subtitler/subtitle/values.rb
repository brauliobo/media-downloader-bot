class Subtitler
  class Subtitle
    # The copies and conversions a subtitle applies to what it is given: its text and lists are frozen,
    # so a caller cannot change them from outside, and its times are finite numbers.
    module Values
      module_function

      def parse_json_object(input)
        input.is_a?(String) ? JSON.parse(input) : input
      rescue JSON::ParserError => error
        raise ArgumentError, "invalid subtitle JSON: #{error.message}"
      end

      def time_value(value, field)
        return number(value, field) if value.is_a?(Numeric)

        Subtitler.parse_timestamp(value) || raise(ArgumentError, "invalid #{field} timestamp")
      end

      def metadata_from(data, known_keys) = data.reject { |key, _| known_keys.include?(key) }

      def text(value) = value.to_s.dup.freeze
      def string_or_nil(value) = value&.to_s&.dup&.freeze
      def list(value) = Array(value).dup.freeze

      def number(value, field)
        Float(value).tap { |number| raise ArgumentError, "#{field} must be finite" unless number.finite? }
      end

      def milliseconds(value, field) = number(value, field) / 1000.0

      def immutable_copy(value)
        case value
        when Hash
          value.to_h { |key, item| [immutable_copy(key), immutable_copy(item)] }.freeze
        when Array
          value.map { |item| immutable_copy(item) }.freeze
        when String
          value.dup.freeze
        else
          value.freeze
        end
      end

      def mutable_copy(value)
        case value
        when Hash
          value.to_h { |key, item| [mutable_copy(key), mutable_copy(item)] }
        when Array
          value.map { |item| mutable_copy(item) }
        when String
          value.dup
        else
          value
        end
      end
    end
  end
end
