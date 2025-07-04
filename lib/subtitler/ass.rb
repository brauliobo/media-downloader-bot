class Subtitler
  module Ass

    STYLE = SymMash.new(
      Fontsize:      20,
      Fontname:      'Roboto Medium',
      PrimaryColour: '&H00ffffff',
      OutlineColour: '&H80000000',
      BorderStyle:   1,
      Alignment:     2,
      MarginV:       32,
      Shadow:        1,
    ).freeze

    def self.from_vtt vtt, portrait: false, mode: :instagram
      require 'cgi'

      # Remove potential BOM and WEBVTT header
      vtt = vtt.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      vtt = vtt.sub(/^\uFEFF/, '')
      vtt = vtt.sub(/^WEBVTT.*?(\r?\n){2}/m, '')

      # Helper to parse VTT/ISO time into seconds
      parse_time = lambda do |t|
        if m = t.match(/(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})/)
          h   = (m[1] || 0).to_i
          min = m[2].to_i
          s   = m[3].to_i
          ms  = m[4].to_i
          h * 3600 + min * 60 + s + ms / 1000.0
        else
          0.0
        end
      end

      # Helper to format seconds into ASS time (H:MM:SS.CS)
      format_time = lambda do |sec|
        sec = sec.to_f
        cs  = ((sec - sec.floor) * 100).round
        cs  = 0 if cs == 100 # carry
        total = sec.floor
        h  = total / 3600
        m  = (total % 3600) / 60
        s  = total % 60
        "%d:%02d:%02d.%02d" % [h, m, s, cs]
      end

      cues = []
      lines = vtt.split(/\r?\n/)
      i = 0
      while i < lines.length
        # skip empty lines
        i += 1 while i < lines.length && lines[i].strip.empty?
        break if i >= lines.length

        # Optional cue identifier (non-time line w/o -->)
        id_line = lines[i]
        if id_line.include?('-->')
          time_line = id_line
        else
          i += 1
          time_line = lines[i]
        end

        start_str, end_str = time_line.split(/\s+-->\s+/)
        i += 1
        text_lines = []
        while i < lines.length && !lines[i].strip.empty?
          text_lines << lines[i]
          i += 1
        end
        cue_text = text_lines.join("\n")
        cues << { start: start_str.strip, end: end_str.strip, text: cue_text }
      end

      # Build ASS header using STYLE constants
      style = STYLE.dup
      style.Fontsize = (style.Fontsize * (portrait ? 0.6 : 1)).round
      # For instagram mode, add a style for background highlight
      highlight_style = '{\\bord2\\shad0\\be1\\3c&H000000&\\4c&H00ffff&}'
      header = <<~ASS_HEADER
        [Script Info]
        ScriptType: v4.00+
        Collisions: Normal
        PlayResX: 384
        PlayResY: 288
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
        Style: Default,#{style.Fontname},#{style.Fontsize},#{style.PrimaryColour},&H0000ffff,#{style.OutlineColour},&H00000000,0,0,0,0,100,100,0,0,#{style.BorderStyle},0,#{style.Shadow},#{style.Alignment},10,10,#{style.MarginV},1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      ASS_HEADER

      ass_events = cues.flat_map do |cue|
        s_sec = parse_time.call(cue[:start])
        e_sec = parse_time.call(cue[:end])
        raw = CGI.unescapeHTML(cue[:text])
        raw.gsub!(/\r?\n/, '\\N')

        if raw.match(/<\d{2}:\d{2}:\d{2}\.\d{3}>/)
          segments = raw.split(/<(\d{2}:\d{2}:\d{2}\.\d{3})>/)
          word_times = []
          index = 1
          while index < segments.size
            time_str = segments[index]
            word_text = segments[index + 1] || ''
            w_start = parse_time.call(time_str)
            next_time_str = segments[index + 2]
            w_end = next_time_str ? parse_time.call(next_time_str) : e_sec
            word_times << [w_start, w_end, word_text.strip]
            index += 2
          end
          all_words = word_times.map { |_,_,w| w }
          case mode.to_sym
          when :instagram
            word_times.each_with_index.map do |(w_start, w_end, word), idx|
              text = all_words.each_with_index.map { |w,i|
                if i == idx
                  "{\\c&H00ffff&}#{highlight_style}#{w}{\\r}{\\c&Hffffff&}"
                else
                  w
                end
              }.join(' ')
              "Dialogue: 0,#{format_time.call(w_start)},#{format_time.call(w_end)},Default,,0,0,0,,#{text}"
            end
          when :karaoke
            # fallback to old karaoke effect
            dur_cs = word_times.map { |w_start, w_end, _| ((w_end-w_start)*100).round }
            karaoke_text = all_words.each_with_index.map { |w,i| "{\\k#{dur_cs[i]}}#{w}" }.join(' ')
            ["Dialogue: 0,#{format_time.call(s_sec)},#{format_time.call(e_sec)},Default,,0,0,0,,#{karaoke_text}"]
          else
            # fallback to instagram
            word_times.each_with_index.map do |(w_start, w_end, word), idx|
              text = all_words.each_with_index.map { |w,i|
                if i == idx
                  "{\\c&H00ffff&}#{highlight_style}#{w}{\\r}{\\c&Hffffff&}"
                else
                  w
                end
              }.join(' ')
              "Dialogue: 0,#{format_time.call(w_start)},#{format_time.call(w_end)},Default,,0,0,0,,#{text}"
            end
          end
        else
          ["Dialogue: 0,#{format_time.call(s_sec)},#{format_time.call(e_sec)},Default,,0,0,0,,#{raw}"]
        end
      end.join("\n")

      header + ass_events + "\n"
    end

  end
end