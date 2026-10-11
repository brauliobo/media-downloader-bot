class Subtitler
  module Ass
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
  end
end
