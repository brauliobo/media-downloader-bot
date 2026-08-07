require 'tempfile'
require_relative '../utils/safety'
require_relative 'segments'
require_relative 'translator'

class Subtitler
  class VTT
    TIMESTAMP = /\A(?:(\d{1,2}):)?(\d{2}):(\d{2})(?:[\.,](\d{3}))?/.freeze

    def self.clean(vtt)
      return vtt unless vtt
      vtt
        .gsub(/\{\\[^}]*\}/, '')
        .gsub(/\\h/i, ' ')
        .gsub(/\\t/i, ' ')
        .gsub(/\\[Nn]/, "\n")
    end

    def self.translate(vtt, to:, from: nil)
      segments = segments_from_vtt(Subtitler.strip_word_tags(clean(vtt)))
      return vtt if segments.empty?

      translated = Subtitler::Translator.translate(
        {segments: segments},
        from:           from,
        to:             to,
        merge_adjacent: false
      )
      build(translated, normalize: false, word_tags: false)
    end

    def self.translate_if_needed(zipper, vtt, tsp, from_lang, to_lang)
      normalized_from = Subtitler.normalize_lang(from_lang)
      normalized_to   = Subtitler.normalize_lang(to_lang)
      return [vtt, normalized_from, tsp] unless normalized_to
      return [vtt, normalized_from, tsp] if normalized_from && normalized_from == normalized_to

      zipper&.stl&.update 'translating'

      if tsp
        tsp = Subtitler::Translator.translate(
          tsp,
          from:           normalized_from,
          to:             normalized_to,
          merge_adjacent: false
        )
        vtt = build(tsp, normalize: false, word_tags: !zipper.opts.nowords)
      else
        vtt = translate(vtt, to: normalized_to, from: normalized_from)
      end

      [vtt, normalized_to, tsp]
    end

    def self.build(verbose_json, normalize: true, word_tags: true, stdsub: nil)
      mash = SymMash.new(verbose_json)
      use_norm = stdsub.nil? ? normalize : stdsub
      if use_norm
        Subtitler::Translator.split_long_segments!(mash, max_chars: Subtitler::Translator::MAX_SUBTITLE_CHARS)
        Segments.merge_adjacent!(mash, max_chars: Subtitler::Translator::MAX_SUBTITLE_CHARS)
      end

      formatter = ->(t) { h, rem = t.divmod(3600); m, s = rem.divmod(60); format('%02d:%02d:%06.3f', h, m, s) }

      out = +"WEBVTT\n\n"
      Array(mash.segments).each do |segment|
        start_time  = formatter.call(segment.start)
        finish_time = formatter.call(segment.end)
        out << "#{start_time} --> #{finish_time}\n"
        out << "#{build_line(segment, formatter, word_tags)}\n\n"
      end
      out
    end

    def self.slice(vtt, from:, to:, rebase: true)
      from_s = hms_to_s(from)
      to_s   = hms_to_s(to)
      out = +"WEBVTT\n\n"
      index = 0

      each_cue(vtt) do |cue|
        timing = cue.find { |line| line.include?('-->') }
        next unless timing

        start_str, finish_str = timing.strip.split('-->').map(&:strip)
        start_sec = hmsms_to_s(start_str)
        finish_sec = hmsms_to_s(finish_str)
        next if finish_sec <= from_s || start_sec >= to_s

        clamped_start = [[start_sec - from_s, 0].max, to_s - from_s].min
        clamped_finish = [[finish_sec - from_s, 0].max, to_s - from_s].min

        start_out, finish_out = if rebase
          [clamped_start, clamped_finish]
        else
          [start_sec, finish_sec]
        end

        text = cue.reject { |line| line == timing }.join.strip
        next if text.blank?

        index += 1
        out << "#{index}\n#{s_to_hmsms(start_out)} --> #{s_to_hmsms(finish_out)}\n#{text}\n\n"
      end

      out
    end

    def self.srt_to_vtt(srt)
      out = +"WEBVTT\n\n"
      buffer = []

      srt.each_line do |line|
        stripped = line.strip
        if stripped.empty?
          flush_buffer(out, buffer)
          next
        end

        if line.include?('-->')
          buffer << line.tr(',', '.')
        elsif stripped =~ /^\d+$/
          next
        else
          buffer << line
        end
      end

      flush_buffer(out, buffer)
      out
    end

    def self.to_vtt(body, ext)
      safe_ext = Utils::Safety.subtitle_ext(ext)
      Tempfile.create(['sub', ".#{safe_ext}"]) do |file|
        file.binmode
        file.write(body)
        file.flush
        vtt, = Sh.run "#{Zipper::FFMPEG} -i #{Sh.escape(file.path)} -c:s webvtt -f webvtt -"
        clean(vtt)
      end
    end

    def self.extract_embedded(zipper, index)
      vtt, = Sh.run "#{Zipper::FFMPEG} -i #{Sh.escape zipper.infile} -map 0:s:#{index} -c:s webvtt -f webvtt -"
      clean(vtt)
    end

    def self.each_cue(vtt)
      return enum_for(:each_cue, vtt) unless block_given?

      cue = []
      vtt.each_line do |line|
        if line.strip.empty?
          yield cue if cue.any?
          cue = []
        else
          cue << line
        end
      end
      yield cue if cue.any?
    end

    def self.segments_from_vtt(vtt)
      each_cue(vtt).filter_map do |cue|
        timing_index = cue.index { |line| line.include?('-->') }
        next unless timing_index

        start_text, end_text = cue.fetch(timing_index).strip.split('-->').map(&:strip)
        text = cue[(timing_index + 1)..].map(&:strip).reject(&:empty?).join(' ')
        next if text.empty?

        SymMash.new(
          text:  text,
          start: hmsms_to_s(start_text),
          end:   hmsms_to_s(end_text),
          words: []
        )
      end
    end

    def self.flush_buffer(out, buffer)
      return if buffer.empty?
      out << buffer.join
      out << "\n"
      buffer.clear
    end

    def self.hms_to_s(hms)
      return unless (match = hms&.match(TIMESTAMP))

      match[1].to_i * 3600 + match[2].to_i * 60 + match[3].to_i
    end

    def self.hmsms_to_s(hms)
      return unless (match = hms&.match(TIMESTAMP))

      base = match[1].to_i * 3600 + match[2].to_i * 60 + match[3].to_i
      base + match[4].to_i / 1000.0
    end

    def self.s_to_hmsms(sec)
      sec = sec.to_f
      hours = (sec / 3600).floor
      mins  = ((sec % 3600) / 60).floor
      secs  = (sec % 60).floor
      ms    = ((sec - sec.floor) * 1000).round
      format('%02d:%02d:%02d.%03d', hours, mins, secs, ms)
    end

    def self.build_line(segment, formatter, word_tags)
      words = Array(segment.words)
      return segment.text.to_s.strip if words.empty?

      words.each_with_index.map do |word, idx|
        token = word.word.to_s.strip
        next token if token.empty?
        word_tags && idx.positive? ? "<#{formatter.call(word.start)}>#{token}" : token
      end.join(' ')
    end

    private_class_method :each_cue, :segments_from_vtt, :flush_buffer,
                         :hms_to_s, :hmsms_to_s, :s_to_hmsms,
                         :build_line
  end
end
