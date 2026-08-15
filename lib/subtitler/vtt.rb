require 'nokogiri'
require 'tempfile'
require_relative '../ffmpeg'
require_relative '../utils/safety'
require_relative 'segments'
require_relative 'timestamps'
require_relative 'translator'

class Subtitler
  class VTT
    def self.clean(vtt)
      return vtt unless vtt
      vtt
        .gsub(/\{\\[^}]*\}/, '')
        .gsub(/\\h/i, ' ')
        .gsub(/\\t/i, ' ')
        .gsub(/\\[Nn]/, "\n")
    end

    def self.translate(vtt, to:, from: nil, word_tags: true)
      segments = segments_from_vtt(clean(vtt))
      return vtt if segments.empty?

      translated = Subtitler::Translator.translate(
        {segments: segments},
        from:           from,
        to:             to,
        merge_adjacent: false
      )
      build(translated, normalize: false, word_tags: word_tags)
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
        vtt = translate(vtt, to: normalized_to, from: normalized_from, word_tags: !zipper.opts.nowords)
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

      formatter = ->(time) { Subtitler.format_timestamp(time) }

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

        clamped_start  = [[start_sec - from_s, 0].max, to_s - from_s].min
        clamped_finish = [[finish_sec - from_s, 0].max, to_s - from_s].min

        start_out, finish_out = if rebase
          [clamped_start, clamped_finish]
        else
          [start_sec, finish_sec]
        end

        text = cue.reject { |line| line == timing }.join.strip
        if rebase && (segment = segments_from_vtt(cue.join).first)
          if Array(segment.words).any?
            words = segment.words.select { |word| word.end.to_f > from_s && word.start.to_f < to_s }.map do |word|
              SymMash.new(word.to_h.merge(
                start: [[word.start.to_f, from_s].max, to_s].min - from_s,
                end:   [[word.end.to_f, from_s].max, to_s].min - from_s
              ))
            end
            next if words.empty?

            rebased = segment.to_h.merge(start: start_out, end: finish_out, words: words)
            text = build_line(SymMash.new(rebased), method(:s_to_hmsms), true)
          else
            text = segment.text.to_s
          end
        end
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

        if stripped.match?(Subtitler::CUE_TIMING)
          timestamps = 0
          buffer << line.gsub(Subtitler::TIMESTAMP_VALUE) do |timestamp|
            timestamps += 1
            timestamps <= 2 ? timestamp.tr(',', '.') : timestamp
          end
        elsif stripped =~ /^\d+$/
          next
        else
          buffer << line.gsub(Subtitler::INLINE_TIMESTAMP) { |timestamp| timestamp.tr(',', '.') }
        end
      end

      flush_buffer(out, buffer)
      out
    end

    def self.to_vtt(body, ext, ffmpeg: FFmpeg.new)
      safe_ext = Utils::Safety.subtitle_ext(ext)
      if safe_ext == 'vtt'
        utf8 = body.dup.force_encoding(Encoding::UTF_8)
        raise Encoding::InvalidByteSequenceError, 'invalid byte sequence in UTF-8' unless utf8.valid_encoding?

        canonical = clean(utf8.gsub(/\r\n?|\r/, "\n"))
        validate_native_vtt!(canonical)
        return canonical
      end

      Tempfile.create(['sub', ".#{safe_ext}"]) do |file|
        file.binmode
        file.write(body)
        file.flush
        vtt = ffmpeg.convert_subtitle(
          input: file.path, format: :vtt, label: 'VTT conversion failed'
        )
        clean(vtt)
      end
    end

    def self.extract_embedded(zipper, index, ffmpeg: FFmpeg.new)
      vtt = ffmpeg.convert_subtitle(
        input: zipper.infile, format: :vtt, stream_index: index,
        label: 'VTT extraction failed'
      )
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
      each_cue(vtt).each_with_index.filter_map do |cue, cue_id|
        timing_index = cue.index { |line| line.include?('-->') }
        next unless timing_index

        start_text, end_text = cue.fetch(timing_index).strip.split('-->').map(&:strip)
        raw_text = cue[(timing_index + 1)..].map(&:strip).reject(&:empty?).join(' ')
        text = semantic_text(raw_text)
        next if text.empty?

        start_time = hmsms_to_s(start_text)
        end_time   = hmsms_to_s(end_text)

        SymMash.new(
          text:   text,
          start:  start_time,
          end:    end_time,
          cue_id: cue_id,
          words:  inline_timed_words(raw_text, start_time, end_time, cue_id)
        )
      end
    end

    def self.inline_timed_words(text, cue_start, cue_end, cue_id)
      matches = text.to_enum(:scan, /<([^>]*)>/).map { Regexp.last_match }
      malformed = matches.any? do |match|
        match[1].match?(/\A\d{1,2}:\d{2}/) && hmsms_to_s_exact(match[1]).nil?
      end
      timed = text.to_enum(:scan, Subtitler::INLINE_TIMESTAMP).filter_map do
        match = Regexp.last_match
        time  = hmsms_to_s_exact(match[1])
        [match, time] if time
      end
      return [] if malformed || timed.empty? || !cue_start || !cue_end

      times = timed.map(&:last)
      return [] unless times.all? { |time| time >= cue_start && time <= cue_end }
      return [] unless times.each_cons(2).all? { |left, right| right > left }

      chunks = []
      cursor = 0
      timed.each do |match, _time|
        chunks << text[cursor...match.begin(0)]
        cursor = match.end(0)
      end
      chunks << text[cursor..]

      boundaries = [cue_start, *times, cue_end]
      chunks.flat_map.with_index do |chunk, index|
        tokens = semantic_text(chunk).split
        next [] if tokens.empty?

        start_time = boundaries.fetch(index)
        end_time   = boundaries.fetch(index + 1)
        return [] unless end_time > start_time

        duration = end_time - start_time
        tokens.map.with_index do |token, token_index|
          token_start = start_time + duration * token_index / tokens.size
          token_end   = token_index == tokens.size - 1 ? end_time : start_time + duration * (token_index + 1) / tokens.size
          SymMash.new(word: token, start: token_start, end: token_end, cue_id: cue_id)
        end
      end
    end

    def self.validate_native_vtt!(vtt)
      header = vtt.each_line.first&.strip
      raise ArgumentError, 'invalid WEBVTT header' unless header&.match?(/\A\uFEFF?WEBVTT(?:[ \t].*)?\z/)

      vtt.each_line.select { |line| line.include?('-->') }.each do |line|
        raise ArgumentError, 'invalid WEBVTT cue timing' unless line.match?(Subtitler::CUE_TIMING)

        start_text, end_text = line.scan(Subtitler::TIMESTAMP_VALUE).first(2)
        start_time  = hmsms_to_s_exact(start_text)
        finish_time = hmsms_to_s_exact(end_text)
        unless start_time && finish_time && finish_time > start_time
          raise ArgumentError, 'invalid WEBVTT cue range'
        end
      end
    end

    def self.semantic_text(text)
      plain = text.to_s.gsub(/<br\s*\/?\s*>/i, ' ').gsub(/<[^>]*>/, '')
      Nokogiri::HTML5.fragment(plain).text.split.join(' ')
    end

    def self.flush_buffer(out, buffer)
      return if buffer.empty?
      out << buffer.join
      out << "\n"
      buffer.clear
    end

    def self.hms_to_s(hms)
      return unless (match = hms&.match(Subtitler::TIMESTAMP))

      match[1].to_i * 3600 + match[2].to_i * 60 + match[3].to_i
    end

    def self.hmsms_to_s(hms)
      return unless (match = hms&.match(Subtitler::TIMESTAMP))

      base = match[1].to_i * 3600 + match[2].to_i * 60 + match[3].to_i
      base + match[4].to_i / 1000.0
    end

    def self.hmsms_to_s_exact(hms)
      match = hms&.match(Subtitler::TIMESTAMP)
      return unless match && match[0].length == hms.length
      return if match[2].to_i >= 60 || match[3].to_i >= 60

      hmsms_to_s(hms)
    end

    def self.s_to_hmsms(sec)
      Subtitler.format_timestamp(sec)
    end

    def self.build_line(segment, formatter, word_tags)
      words = Array(segment.words)
      return segment.text.to_s.strip if words.empty?

      last_marker = nil
      words.each_with_index.map do |word, idx|
        token = word.word.to_s.strip
        next token if token.empty?

        marker_time = word.start.to_f
        tagged = word_tags && (idx.positive? || marker_time > segment.start.to_f) &&
                 marker_time < segment.end.to_f && marker_time != last_marker
        last_marker = marker_time if tagged
        tagged ? "<#{formatter.call(marker_time)}>#{token}" : token
      end.join(' ')
    end

    private_class_method :each_cue, :segments_from_vtt, :inline_timed_words,
                         :validate_native_vtt!, :semantic_text, :flush_buffer, :hms_to_s,
                         :hmsms_to_s, :hmsms_to_s_exact, :s_to_hmsms,
                         :build_line
  end
end
