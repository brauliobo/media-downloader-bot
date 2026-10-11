class Subtitler
  module Ass
    class Style
      DEFAULTS = {
        'Name'            => 'Default',
        'Fontname'        => 'Arial',
        'Fontsize'        => 20,
        'PrimaryColour'   => '&H00FFFFFF',
        'SecondaryColour' => '&H000000FF',
        'OutlineColour'   => '&H00000000',
        'BackColour'      => '&H00000000',
        'Bold'            => 0,
        'Italic'          => 0,
        'Underline'       => 0,
        'StrikeOut'       => 0,
        'ScaleX'          => 100,
        'ScaleY'          => 100,
        'Spacing'         => 0,
        'Angle'           => 0,
        'BorderStyle'     => 1,
        'Outline'         => 0,
        'Shadow'          => 0,
        'Alignment'       => 2,
        'MarginL'         => 10,
        'MarginR'         => 10,
        'MarginV'         => 10,
        'Encoding'        => 1,
      }.freeze

      attr_reader :values, :extensions

      def initialize(extensions: {}, **attributes)
        @values     = DEFAULTS.merge(normalize(attributes)).freeze
        @extensions = normalize(extensions).freeze
      end

      def [](field)
        @values[field.to_s] || @extensions[field.to_s]
      end

      def serialize(fields = STYLE_FIELDS)
        fields.map { |field| self[field] }.join(',')
      end

      private

      def normalize(attributes)
        attributes.to_h do |key, value|
          name = STYLE_FIELDS.find { |field| normalize_name(field) == normalize_name(key) } || key.to_s
          [name, value]
        end
      end

      def normalize_name(name)
        name.to_s.delete('_').downcase
      end
    end
  end
end
