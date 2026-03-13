class Subtitler
  module Ass

    BASE_STYLE = {
      Fontsize:      20,
      Fontname:      'Roboto Medium',
      PrimaryColour: '&H00ffffff',
      Alignment:     2,
      MarginV:       32,
    }.freeze

    PRESETS = {
      # YouTube-like: semi-transparent black background box + word highlighting.
      # BorderStyle 4 is a libass extension: one opaque box per event, drawn at the
      # event level — unlike BorderStyle 3 which stacks a new box for every event
      # active simultaneously, causing the double-box / overlap artifact.
      # Outline controls the horizontal/vertical padding, Shadow must be 0.
      'default' => BASE_STYLE.merge(
        OutlineColour: '&HFF000000',  # fully transparent — no text outline inside the box
        BackColour:    '&H80000000',  # 50% transparent black box (YouTube style)
        BorderStyle:   4,
        Outline:       4,             # controls box padding, not visible outline colour
        Shadow:        0,
      ).freeze,
      # Original look: outline + shadow, no background box
      'nobg' => BASE_STYLE.merge(
        OutlineColour: '&H80000000',
        BackColour:    '&H00000000',
        BorderStyle:   1,
        Outline:       0,
        Shadow:        2,
      ).freeze,
    }.freeze

    SECONDARY_COLOUR = '&H0000ffff'.freeze # yellow

    HEADER_TEMPLATE = <<~ASS_HEADER.freeze
      [Script Info]
      ScriptType: v4.00+
      Collisions: Normal
      PlayResX: 384
      PlayResY: 288
      WrapStyle: 0
      ScaledBorderAndShadow: yes

      [V4+ Styles]
      Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
      Style: Default,%{Fontname},%{Fontsize},%{PrimaryColour},#{SECONDARY_COLOUR},%{OutlineColour},%{BackColour},0,0,0,0,100,100,0,0,%{BorderStyle},%{Outline},%{Shadow},%{Alignment},10,10,%{MarginV},1

      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    ASS_HEADER

    # Highlight tag applied to the current word.
    # For 'default' (BS4 bg preset): only change \1c (text colour) — never \4c.
    HIGHLIGHT_STYLES = {
      'default' => '{\\1c&H00ffff&}'.freeze,
      'nobg'    => '{\\bord2\\shad0\\be1\\3c&H000000&\\4c&H00ffff&}'.freeze,
    }.freeze

    # Tag to restore normal text colour after a highlighted word.
    RESET_COLOUR = {
      'default' => '{\\1c&Hffffff&}'.freeze,
      'nobg'    => '{\\r}{\\c&Hffffff&}'.freeze,
    }.freeze

    TIMESTAMP = /(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})/.freeze
    INLINE_TS = /<\d{2}:\d{2}:\d{2}\.\d{3}>/.freeze

    # Convert VTT timestamp to seconds
    def self.parse_time t
      return 0.0 unless (m = t.match(TIMESTAMP))
      h = (m[1] || 0).to_i; (h*3600) + m[2].to_i*60 + m[3].to_i + m[4].to_i/1000.0
    end

    # Format seconds to ASS time (H:MM:SS.CS)
    def self.ass_time sec
      cs = ((sec = sec.to_f) - sec.floor)*100
      total = sec.floor
      h, remainder = total.divmod 3600
      m, s = remainder.divmod 60
      "%d:%02d:%02d.%02d" % [h, m, s, cs.round]
    end

    def self.from_vtt vtt, portrait: false, mode: :instagram, preset: 'default'
      require 'cgi'

      preset = preset.to_s
      preset = 'default' unless PRESETS.key?(preset)
      highlight_style = HIGHLIGHT_STYLES[preset] || HIGHLIGHT_STYLES['default']
      reset_colour    = RESET_COLOUR[preset]    || RESET_COLOUR['nobg']

      vtt = vtt.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      vtt = vtt.sub(/^\uFEFF/, '').sub(/^WEBVTT.*?(\r?\n){2}/m, '')

      cues = vtt.split(/\r?\n\r?\n+/).filter_map do |block|
        lines = block.split(/\r?\n/)
        t_idx = lines.index { |l| l.include?('-->') }
        next unless t_idx
        time_line = lines[t_idx]
        times = time_line.scan(/(\d{2}:\d{2}\.\d{3}|\d+:\d{2}:\d{2}\.\d{3})/).flatten
        start_str, end_str = times[0], times[1]
        next unless start_str && end_str
        { start: start_str, end: end_str, text: (lines[(t_idx+1)..-1] || []).join("\n") }
      end

      # Build ASS header using preset style and template
      style = PRESETS[preset].dup
      style[:Fontsize] = (style[:Fontsize] * (portrait ? 0.6 : 1)).round
      header = HEADER_TEMPLATE % style

      mode_sym = (mode || :instagram).to_sym
      ass_events = cues.flat_map do |cue|
        s_sec = parse_time(cue[:start]); e_sec = parse_time(cue[:end])
        raw = CGI.unescapeHTML(cue[:text]).gsub(/\r?\n/, '\\N')
        raw = raw.gsub(INLINE_TS, '') if mode_sym == :plain
        if raw.match?(INLINE_TS)
          wt = word_segments(raw, s_sec, e_sec)
          words = wt.map { |_,_,w| w }
          case mode_sym
          when :instagram
            # Each word gets its own event spanning [ws, we].
            # With BorderStyle 4 (default preset), each event draws its own box but
            # boxes don't compound/stack visually — BS4 draws at the event level, not
            # additively. Non-bg presets (nobg) have no box so no overlap risk either.
            wt.each_with_index.map do |(ws, we, _), i|
              highlighted = words.each_with_index.map do |w, idx|
                idx == i ? "#{highlight_style}#{w}#{reset_colour}" : w
              end.join(' ')
              dialogue(ws, we, highlighted)
            end
          when :karaoke
            durs = wt.map { |ws,we,_| ((we-ws)*100).round }
            [dialogue(s_sec, e_sec, words.each_with_index.map { |w,i| "{\\k#{durs[i]}}#{w}" }.join(' '))]
          end
        else
          [dialogue(s_sec, e_sec, raw)]
        end
      end.join("\n")

      header + ass_events + "\n"
    end

    def self.dialogue start_sec, end_sec, text
      "Dialogue: 0,#{ass_time(start_sec)},#{ass_time(end_sec)},Default,,0,0,0,,#{text}"
    end

    def self.word_segments raw, s_sec, e_sec
      segs = raw.split(/<(\d{2}:\d{2}:\d{2}\.\d{3})>/)
      list = []
      first = segs.first&.strip
      list << [s_sec, segs.length > 1 ? parse_time(segs[1]) : e_sec, first] if first && !first.empty?
      index = 1
      while index < segs.size
        time_str = segs[index]
        word_text = (segs[index + 1] || '').strip
        unless word_text.empty?
          w_start = parse_time(time_str)
          next_time_str = segs[index + 2]
          w_end = next_time_str ? parse_time(next_time_str) : e_sec
          list << [w_start, w_end, word_text]
        end
        index += 2
      end
      list
    end

  end
end