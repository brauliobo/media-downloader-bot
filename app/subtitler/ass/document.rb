class Subtitler
  module Ass
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
  end
end
