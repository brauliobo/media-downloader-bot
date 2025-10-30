class Subtitler
  class VTT
    SKIP_TAGS = %w[NOTE STYLE REGION].freeze

    def self.clean(vtt)
      return vtt unless vtt
      vtt
        .gsub(/\{\\[^}]*\}/, '')
        .gsub(/\\h/i, ' ')
        .gsub(/\\t/i, ' ')
        .gsub(/\\[Nn]/, "\n")
    end

    def self.translate(vtt, to:, from: nil)
      lines = vtt.lines
      indexes = []
      originals = []

      lines.each_with_index do |line, idx|
        stripped = line.strip
        next if skip_line?(stripped, idx)
        indexes << idx
        originals << stripped
      end

      translations = translate_chunks(originals, from: from, to: to)

      indexes.each_with_index do |line_idx, pos|
        replacement = translations[pos] || originals[pos]
        lines[line_idx] = lines[line_idx].sub(originals[pos], replacement.to_s)
      end

      lines.join
    end

    def self.translate_if_needed(zipper, vtt, tsp, from_lang, to_lang)
      normalized_from = Subtitler.normalize_lang(from_lang)
      normalized_to   = Subtitler.normalize_lang(to_lang)
      return [vtt, normalized_from, tsp] unless normalized_to
      return [vtt, normalized_from, tsp] if normalized_from && normalized_from == normalized_to

      zipper&.stl&.update 'translating'

      if tsp
        tsp = Subtitler.translate(tsp, from: normalized_from, to: normalized_to)
        vtt = build(tsp, word_tags: !zipper.opts.nowords)
      else
        vtt = translate(vtt, to: normalized_to, from: normalized_from)
      end

      [vtt, normalized_to, tsp]
    end

    def self.build(verbose_json, normalize: true, word_tags: true, stdsub: nil)
      mash = SymMash.new(verbose_json)
      use_norm = stdsub.nil? ? normalize : stdsub
      merge_segments!(mash) if use_norm

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
      File.write "sub.#{ext}", body
      vtt, = Sh.run "#{Zipper::FFMPEG} -i sub.#{ext} -c:s webvtt -f webvtt -"
      clean(vtt)
    end

    def self.extract_embedded(zipper, index)
      vtt, = Sh.run "#{Zipper::FFMPEG} -i #{Sh.escape zipper.infile} -map 0:s:#{index} -c:s webvtt -f webvtt -"
      clean(vtt)
    end

    def self.translate_chunks(chunks, from:, to:)
      return [] if chunks.empty?

      chunks.each_slice(::Translator::BATCH_SIZE).flat_map do |slice|
        Array(::Translator.translate(slice, from: from, to: to)).map(&:to_s)
      end
    end

    def self.skip_line?(text, index)
      text.empty? || text.include?('-->') || SKIP_TAGS.any? { |tag| text.start_with?(tag) } || (index.zero? && text.start_with?('WEBVTT'))
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

    def self.flush_buffer(out, buffer)
      return if buffer.empty?
      out << buffer.join
      out << "\n"
      buffer.clear
    end

    def self.hms_to_s(hms)
      return unless hms
      if hms =~ /(\d{1,2}):(\d{2}):(\d{2})/
        Regexp.last_match(1).to_i * 3600 + Regexp.last_match(2).to_i * 60 + Regexp.last_match(3).to_i
      end
    end

    def self.hmsms_to_s(hms)
      return unless hms
      if hms =~ /(\d{1,2}):(\d{2}):(\d{2})([\.,](\d{3}))?/
        base = Regexp.last_match(1).to_i * 3600 + Regexp.last_match(2).to_i * 60 + Regexp.last_match(3).to_i
        ms = Regexp.last_match(5).to_i
        base + ms / 1000.0
      end
    end

    def self.s_to_hmsms(sec)
      sec = sec.to_f
      hours = (sec / 3600).floor
      mins  = ((sec % 3600) / 60).floor
      secs  = (sec % 60).floor
      ms    = ((sec - sec.floor) * 1000).round
      format('%02d:%02d:%02d.%03d', hours, mins, secs, ms)
    end

    def self.merge_segments!(mash, max_chars: 84, gap_threshold: 1.0)
      segments = Array(mash.segments)
      return mash if segments.empty?

      merged = []
      current = segments.first

      segments.drop(1).each do |segment|
        if mergeable?(current, segment, max_chars, gap_threshold)
          merge_segment!(current, segment)
        else
          merged << current
          current = segment
        end
      end

      merged << current if current
      mash.segments = merged
      mash
    end

    def self.mergeable?(left, right, max_chars, gap_threshold)
      gap = right.start.to_f - left.end.to_f
      combined = left.text.to_s.length + 1 + right.text.to_s.length
      gap <= gap_threshold && combined <= max_chars
    end

    def self.merge_segment!(left, right)
      texts = [left.text, right.text].map { |text| text.to_s.strip }.reject(&:empty?)
      left.text = texts.join(' ')
      left.end  = right.end
      left.words ||= []
      left.words.concat(Array(right.words))
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

    private_class_method :translate_chunks, :skip_line?, :each_cue, :flush_buffer,
                         :hms_to_s, :hmsms_to_s, :s_to_hmsms,
                         :merge_segments!, :mergeable?, :merge_segment!, :build_line
  end
end


