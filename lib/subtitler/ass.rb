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
      Style: Default,%{Fontname},%{Fontsize},%{PrimaryColour},#{SECONDARY_COLOUR},%{OutlineColour},&H00000000,0,0,0,0,100,100,0,0,%{BorderStyle},0,%{Shadow},%{Alignment},10,10,%{MarginV},1

      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    ASS_HEADER

    HIGHLIGHT_STYLE = '{\\bord2\\shad0\\be1\\3c&H000000&\\4c&H00ffff&}'.freeze

    # Convert VTT timestamp to seconds
    def self.parse_time t
      return 0.0 unless (m = t.match(/(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})/))
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

    def self.from_vtt vtt, portrait: false, mode: :instagram
      require 'cgi'

      # Remove potential BOM and WEBVTT header
      vtt = vtt.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      vtt = vtt.sub(/^\uFEFF/, '')
      vtt = vtt.sub(/^WEBVTT.*?(\r?\n){2}/m, '')

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

      # Build ASS header using STYLE constants and template
      style = STYLE.dup
      style.Fontsize = (style.Fontsize * (portrait ? 0.6 : 1)).round
      header = HEADER_TEMPLATE % style

      ass_events = cues.flat_map do |cue|
        s_sec = parse_time(cue[:start])
        e_sec = parse_time(cue[:end])
        raw = CGI.unescapeHTML(cue[:text])
        raw.gsub!(/\r?\n/, '\\N')

        if raw.match(/<\d{2}:\d{2}:\d{2}\.\d{3}>/)
          segments = raw.split(/<(\d{2}:\d{2}:\d{2}\.\d{3})>/)
          word_times = []

          # Handle first word, which doesn't have a preceding timestamp tag
          first_word = segments.first&.strip
          if first_word && !first_word.empty?
            w_end = segments.length > 1 ? parse_time(segments[1]) : e_sec
            word_times << [s_sec, w_end, first_word]
          end

          index = 1
          while index < segments.size
            time_str = segments[index]
            word_text = segments[index + 1] || ''
            unless word_text.strip.empty?
              w_start = parse_time(time_str)
              next_time_str = segments[index + 2]
              w_end = next_time_str ? parse_time(next_time_str) : e_sec
              word_times << [w_start, w_end, word_text.strip]
            end
            index += 2
          end
          all_words = word_times.map { |_,_,w| w }
          case mode.to_sym
          when :instagram
            word_times.each_with_index.map do |(w_start, w_end, word), idx|
              text = all_words.each_with_index.map { |w,i|
                if i == idx
                  "{\\c&H00ffff&}#{HIGHLIGHT_STYLE}#{w}{\\r}{\\c&Hffffff&}"
                else
                  w
                end
              }.join(' ')
              "Dialogue: 0,#{ass_time(w_start)},#{ass_time(w_end)},Default,,0,0,0,,#{text}"
            end
          when :karaoke
            dur_cs = word_times.map { |w_start, w_end, _| ((w_end-w_start)*100).round }
            karaoke_text = all_words.each_with_index.map { |w,i| "{\\k#{dur_cs[i]}}#{w}" }.join(' ')
            ["Dialogue: 0,#{ass_time(s_sec)},#{ass_time(e_sec)},Default,,0,0,0,,#{karaoke_text}"]
          end
        else
          ["Dialogue: 0,#{ass_time(s_sec)},#{ass_time(e_sec)},Default,,0,0,0,,#{raw}"]
        end
      end.join("\n")

      header + ass_events + "\n"
    end

  end
end