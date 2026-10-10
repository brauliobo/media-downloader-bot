class Subtitler
  class Subtitle
    # Every value a subtitle holds is checked on the way in and frozen, so what it
    # reads later was already validated.
    module Types
      module_function

      def parse_json_object(input)
        input = JSON.parse(input) if input.is_a?(String)
        json_object(input, 'subtitle')
      rescue JSON::ParserError => error
        raise ArgumentError, "invalid subtitle JSON: #{error.message}"
      end

      def time_value(value, field)
        return number(value, field) if value.is_a?(Numeric)

        parsed = Subtitler.parse_timestamp(value)
        raise ArgumentError, "invalid #{field} timestamp" unless parsed

        parsed
      end

      def json_object(value, field)
        raise TypeError, "#{field} must be a Hash" unless value.is_a?(Hash)
        raise ArgumentError, "#{field} keys must be strings" unless value.keys.all? { |key| key.is_a?(String) }

        value
      end

      def fetch_array(data, field)
        value = data.fetch(field)
        raise TypeError, "#{field} must be an Array" unless value.is_a?(Array)

        value
      end

      def optional_array(value, field)
        return [] if value.nil?
        raise TypeError, "#{field} must be an Array" unless value.is_a?(Array)

        value
      end

      def metadata_from(data, known_keys)
        data.reject { |key, _| known_keys.include?(key) }
      end

      def optional_string(value, field)
        return if value.nil?

        string(value, field)
      end

      def optional_text(value, field)
        value.nil? ? ''.freeze : string(value, field)
      end

      def string(value, field)
        raise TypeError, "#{field} must be a String" unless value.is_a?(String)

        value.dup.freeze
      end

      def milliseconds(value, field) = number(value, field) / 1000.0

      def number(value, field)
        raise TypeError, "#{field} must be Numeric" unless value.is_a?(Numeric)
        raise ArgumentError, "#{field} must be finite" unless value.finite?

        value.to_f
      end

      def typed_array(value, type, field)
        raise TypeError, "#{field} must be an Array" unless value.is_a?(Array)
        raise TypeError, "#{field} must contain only #{type}" unless value.all? { |item| item.is_a?(type) }

        value.dup.freeze
      end

      def immutable_hash(value, field)
        raise TypeError, "#{field} must be a Hash" unless value.is_a?(Hash)

        immutable_copy(value)
      end

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
