require_relative 'timestamps'

class Subtitler
  module Ass
    STYLE_FIELDS = %w[
      Name Fontname Fontsize PrimaryColour SecondaryColour OutlineColour BackColour
      Bold Italic Underline StrikeOut ScaleX ScaleY Spacing Angle BorderStyle Outline
      Shadow Alignment MarginL MarginR MarginV Encoding
    ].freeze
    EVENT_FIELDS = %w[Layer Start End Style Name MarginL MarginR MarginV Effect Text].freeze

    SCRIPT_INFO = {
      'ScriptType'            => 'v4.00+',
      'Collisions'            => 'Normal',
      'PlayResX'              => 384,
      'PlayResY'              => 288,
      'WrapStyle'             => 0,
      'ScaledBorderAndShadow' => 'yes',
    }.freeze

    BASE_STYLE = {
      'Fontname'      => 'Roboto Medium',
      'Fontsize'      => 20,
      'PrimaryColour' => '&H00ffffff',
      'Alignment'     => 2,
      'MarginV'       => 32,
    }.freeze

    UNSPOKEN_COLOUR  = 'C0C0C0'.freeze
    WHITE_TAG        = '{\1c&Hffffff&}'.freeze
    SECONDARY_COLOUR = '&H0000ffff'.freeze

    BOX_STYLE = {
      'OutlineColour' => '&HFF000000',
      'BackColour'    => '&H80000000',
      'BorderStyle'   => 4,
      'Outline'       => 4,
      'Shadow'        => 0,
    }.freeze

    BOX_PRESET = BASE_STYLE.merge(BOX_STYLE).freeze
    PRESETS = {
      'default' => BOX_PRESET,
      'hlword'  => BOX_PRESET,
      'nobg'    => BASE_STYLE.merge(
        'OutlineColour' => '&H80000000',
        'BackColour'    => '&H00000000',
        'BorderStyle'   => 1,
        'Outline'       => 0,
        'Shadow'        => 2,
      ).freeze,
    }.freeze

    HIGHLIGHT_STYLES = {
      'default' => WHITE_TAG,
      'hlword'  => '{\1c&H00ffff&}'.freeze,
      'nobg'    => '{\bord2\shad0\be1\3c&H000000&\4c&H00ffff&}'.freeze,
    }.freeze

    RESET_COLOUR = {
      'default' => "{\\1c&H#{UNSPOKEN_COLOUR}&}".freeze,
      'hlword'  => WHITE_TAG,
      'nobg'    => "{\\r}#{WHITE_TAG}".freeze,
    }.freeze

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

    class Event
      attr_reader :layer, :start, :finish, :style, :name, :margin_l, :margin_r, :margin_v,
                  :effect, :text, :extensions

      def initialize(start:, finish:, text:, layer: 0, style: 'Default', name: '',
        margin_l: 0, margin_r: 0, margin_v: 0, effect: '', extensions: {})
        @layer      = layer
        @start      = start.to_f
        @finish     = finish.to_f
        @style      = style
        @name       = name
        @margin_l   = margin_l
        @margin_r   = margin_r
        @margin_v   = margin_v
        @effect     = effect
        @text       = text.to_s
        @extensions = extensions.transform_keys(&:to_s).freeze
        raise ArgumentError, 'finish must not precede start' if @finish < @start
      end

      def serialize(fields = EVENT_FIELDS)
        fields.map { |field| value_for(field) }.join(',')
      end

      private

      def value_for(field)
        case field
        when 'Layer'   then @layer
        when 'Start'   then Ass.ass_time(@start)
        when 'End'     then Ass.ass_time(@finish)
        when 'Style'   then @style
        when 'Name'    then @name
        when 'MarginL' then @margin_l
        when 'MarginR' then @margin_r
        when 'MarginV' then @margin_v
        when 'Effect'  then @effect
        when 'Text'    then @text
        else @extensions[field]
        end
      end
    end

    class Document
      attr_reader :script_info, :styles, :events, :sections, :style_fields, :event_fields

      def initialize(script_info: SCRIPT_INFO, styles: [], events: [], sections: {},
        style_fields: STYLE_FIELDS, event_fields: EVENT_FIELDS)
        @script_info  = script_info.dup.freeze
        @styles       = styles.dup.freeze
        @events       = events.dup.freeze
        @sections     = sections.transform_values { |lines| Array(lines).dup.freeze }.freeze
        @style_fields = style_fields.dup.freeze
        @event_fields = event_fields.dup.freeze
      end

      def to_s
        out = +"[Script Info]\n"
        @script_info.each { |key, value| out << "#{key}: #{value}\n" }
        out << "\n[V4+ Styles]\n"
        out << "Format: #{@style_fields.join(',')}\n"
        @styles.each { |style| out << "Style: #{style.serialize(@style_fields)}\n" }
        out << "\n[Events]\n"
        out << "Format: #{@event_fields.join(', ')}\n"
        @events.each { |event| out << "Dialogue: #{event.serialize(@event_fields)}\n" }
        @sections.each do |name, lines|
          out << "\n[#{name}]\n"
          lines.each { |line| out << "#{line}\n" }
        end
        out
      end
      alias to_ass to_s
    end

    module_function

    def parse_time(timestamp)
      Subtitler.parse_timestamp(timestamp)
    end

    def ass_time(seconds)
      Subtitler.format_timestamp(seconds, precision: 2, hour_digits: 1)
    end

    def from_vtt(vtt, portrait: false, mode: :instagram, preset: 'default')
      Subtitler::Subtitle.from_vtt(vtt).to_ass(portrait: portrait, mode: mode, preset: preset)
    end

    def document_for(subtitle, portrait: false, mode: :instagram, preset: 'default')
      raise TypeError, 'subtitle must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitler::Subtitle)

      preset = preset.to_s
      preset = 'default' unless PRESETS.key?(preset)
      style  = style_for(preset, portrait)
      events = subtitle.entries.flat_map { |entry| events_for(entry, mode, preset) }
      Document.new(styles: [style], events: events)
    end

    def style_for(preset, portrait)
      values = PRESETS.fetch(preset).dup
      values['Fontsize'] = (values.fetch('Fontsize') * (portrait ? 0.6 : 1)).round
      Style.new(
        **values.merge(
          'Name'            => 'Default',
          'SecondaryColour' => SECONDARY_COLOUR,
          'Bold'            => 0,
          'Italic'          => 0,
          'Underline'       => 0,
          'StrikeOut'       => 0,
          'ScaleX'          => 100,
          'ScaleY'          => 100,
          'Spacing'         => 0,
          'Angle'           => 0,
          'MarginL'         => 10,
          'MarginR'         => 10,
          'Encoding'        => 1,
        )
      )
    end

    def events_for(entry, mode, preset)
      mode = (mode || :instagram).to_sym
      return [Event.new(start: entry.start, finish: entry.finish, text: ass_text(entry))] if mode == :plain || entry.words.empty?

      groups = word_groups(entry)
      words  = groups.map { |group| group[:text] }
      case mode
      when :instagram
        groups.map.with_index do |group, index|
          highlighted = words.map.with_index do |text, word_index|
            if word_index == index
              "#{HIGHLIGHT_STYLES.fetch(preset)}#{text}#{RESET_COLOUR.fetch(preset)}"
            else
              text
            end
          end.join(' ')
          Event.new(start: group[:start], finish: group[:finish], text: highlighted)
        end
      when :karaoke
        text = groups.map do |group|
          duration = ((group[:finish] - group[:start]) * 100).round
          "{\\k#{duration}}#{group[:text]}"
        end.join(' ')
        [Event.new(start: entry.start, finish: entry.finish, text: text)]
      else
        []
      end
    end

    def ass_text(entry)
      entry.metadata.fetch('ass_text', entry.text).gsub(/\r?\n/, '\\N')
    end

    def word_groups(entry)
      entry.words.chunk_while do |left, right|
        left.metadata.key?('marker_group') &&
          left.metadata['marker_group'] == right.metadata['marker_group']
      end.map do |words|
        {
          start:  words.first.start,
          finish: words.last.finish,
          text:   words.map { |word| word.text.strip }.join(' '),
        }
      end
    end

    private_class_method :style_for, :events_for, :ass_text, :word_groups
  end
end
