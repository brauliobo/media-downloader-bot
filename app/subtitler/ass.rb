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

    module_function

    def ass_time(seconds)
      Subtitler.format_timestamp(seconds, precision: 2, hour_digits: 1)
    end

    def document_for(subtitle, portrait: false, mode: :instagram, preset: 'default')
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
      case mode
      when :instagram
        words = groups.map { |group| group[:text] }
        event_bounds(entry, groups).each_cons(2).with_index.filter_map do |(start_time, finish_time), index|
          next unless finish_time > start_time

          highlighted = words.map.with_index do |text, word_index|
            word_index == index ? "#{HIGHLIGHT_STYLES.fetch(preset)}#{text}#{RESET_COLOUR.fetch(preset)}" : text
          end.join(' ')
          Event.new(start: start_time, finish: finish_time, text: highlighted)
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
      metadata = entry.metadata
      text = if metadata.key?('ass_text') &&
        (!metadata.key?('source_text') || metadata['source_text'] == entry.text)
        metadata['ass_text']
      else
        entry.text
      end
      text.gsub(/\r?\n/, '\\N')
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

    def event_bounds(entry, groups)
      times = [entry.start, *groups.drop(1).map { |group| group[:start] }, entry.finish]
      times.map! { |time| time.clamp(entry.start, entry.finish) }
      times.each_index { |i| times[i] = times[i - 1] if i.positive? && times[i] < times[i - 1] }
      times
    end

    private_class_method :style_for, :events_for, :ass_text, :word_groups, :event_bounds
  end
end
