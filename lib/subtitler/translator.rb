require_relative '../text_helpers'

class Subtitler
  class Translator

    MAX_SUBTITLE_CHARS = 84

    def self.translate(verbose_json, from:, to:)
      mash       = SymMash.new(verbose_json)
      sentences  = sentences_for(mash.segments || [])
      texts      = sentences.map(&:text)
      tl_texts   = batch_translate_texts(texts, from: from, to: to)
      apply_translations!(sentences, tl_texts)
      mash.segments = rebuild_segments(sentences)
      split_long_segments!(mash, max_chars: MAX_SUBTITLE_CHARS)
      merge_segments_for_stdsub(mash, max_chars: MAX_SUBTITLE_CHARS)
      mash
    end

    def self.batch_size
      defined?(::Translator::BATCH_SIZE) ? ::Translator::BATCH_SIZE : 50
    end

    def self.sentences_for(segs)
      return [] if segs.nil?
      return TextHelpers.sentences_from_segments(segs) if segs.any? { |s| Array(s.words).any? }
      segs.map { |s| SymMash.new(text: s.text.to_s, start: s.start, end: s.end, words: Array(s.words)) }
    end

    def self.batch_translate_texts(texts, from:, to:)
      texts.each_slice(batch_size).flat_map { |slice| Array(::Translator.translate(slice, from: from, to: to)) }
    end

    def self.apply_translations!(sentences, tl_texts)
      sentences.zip(tl_texts).each do |sent, ttext|
        sent.text = ttext.to_s
        next if Array(sent.words).empty?
        assign_tokens_to_words!(sent, tokenize_text(sent.text))
      end
    end

    def self.rebuild_segments(sentences)
      sentences.map do |s|
        s.text = s.words.any? ? s.words.map { |w| w.word.to_s.strip }.join(' ') : s.text.to_s
        s
      end
    end

    def self.split_long_segments!(mash, max_chars:)
      segments = Array(mash.segments)
      mash.segments = segments.flat_map { |seg| split_segment(seg, max_chars) }
      mash
    end

    def self.split_segment(seg, max_chars)
      text = seg.text.to_s.strip
      return [seg] if text.length <= max_chars
      words = Array(seg.words).reject { |w| w.word.to_s.strip.empty? }
      return split_segment_without_words(seg, max_chars) if words.empty?
      min_next_size = (max_chars * 0.35).to_i
      buckets = []
      buffer = []
      remaining = words.dup
      words.each_with_index do |word, idx|
        sample = (buffer + [word]).map { |w| w.word.to_s.strip }.join(' ').strip
        if sample.length > max_chars && buffer.any?
          next_words = remaining[idx..-1] || []
          next_text = next_words.map { |w| w.word.to_s.strip }.join(' ').strip
          if next_text.length < min_next_size && buffer.size > 1
            split_idx = find_balanced_split(buffer, max_chars, min_next_size, next_text.length)
            if split_idx && split_idx < buffer.size - 1
              buckets << buffer[0..split_idx]
              buffer = buffer[(split_idx + 1)..-1] + [word]
            else
              buckets << buffer
              buffer = [word]
            end
          else
            buckets << buffer
            buffer = [word]
          end
        else
          buffer << word
        end
      end
      buckets << buffer if buffer.any?
      buckets.map { |chunk| build_segment(seg, chunk) }
    end

    def self.find_balanced_split(buffer, max_chars, min_next_size, next_remaining)
      return nil if buffer.size <= 1
      best_idx = nil
      best_score = Float::INFINITY
      (0..buffer.size - 2).each do |idx|
        first_text = buffer[0..idx].map { |w| w.word.to_s.strip }.join(' ').strip
        next_text = buffer[(idx + 1)..-1].map { |w| w.word.to_s.strip }.join(' ').strip
        next_total = next_text.length + next_remaining
        next if first_text.length > max_chars || next_total < min_next_size
        score = (max_chars - first_text.length).abs + (min_next_size - next_total).abs
        if score < best_score
          best_score = score
          best_idx = idx
        end
      end
      best_idx
    end

    def self.build_segment(source, words)
      clones = words.map { |w| SymMash.new(w.to_h) }
      data   = source.to_h
      SymMash.new(data.merge(
        text: clones.map { |w| w.word.to_s.strip }.join(' '),
        start: clones.first&.start || source.start,
        end: clones.last&.end   || source.end,
        words: clones
      ))
    end

    def self.split_segment_without_words(seg, max_chars)
      text = seg.text.to_s.strip
      return [seg] if text.length <= max_chars
      tokens = text.split(/\s+/)
      min_next_size = (max_chars * 0.35).to_i
      parts  = []
      bucket = []
      remaining = tokens.dup
      tokens.each_with_index do |tok, idx|
        sample = ([*bucket, tok].join(' ')).strip
        if sample.length > max_chars && bucket.any?
          next_tokens = remaining[idx..-1] || []
          next_text = next_tokens.join(' ').strip
          if next_text.length < min_next_size && bucket.size > 1
            split_idx = find_balanced_split_tokens(bucket, max_chars, min_next_size, next_text.length)
            if split_idx && split_idx < bucket.size - 1
              parts << bucket[0..split_idx].join(' ')
              bucket = bucket[(split_idx + 1)..-1] + [tok]
            else
              parts << bucket.join(' ')
              bucket = [tok]
            end
          else
            parts << bucket.join(' ')
            bucket = [tok]
          end
        else
          bucket << tok
        end
      end
      parts << bucket.join(' ') if bucket.any?
      return [seg] if parts.size <= 1
      total    = parts.sum(&:length)
      duration = [seg.end.to_f - seg.start.to_f, 0].max
      cursor   = seg.start.to_f
      parts.map.with_index do |part, idx|
        span = total.zero? ? 0 : duration * part.length.to_f / total
        dup  = SymMash.new(seg.to_h)
        dup.text  = part
        dup.words = []
        dup.start = cursor
        cursor   += span
        dup.end   = idx == parts.length - 1 ? seg.end : cursor
        dup
      end
    end

    def self.find_balanced_split_tokens(bucket, max_chars, min_next_size, next_remaining)
      return nil if bucket.size <= 1
      best_idx = nil
      best_score = Float::INFINITY
      (0..bucket.size - 2).each do |idx|
        first_text = bucket[0..idx].join(' ').strip
        next_text = bucket[(idx + 1)..-1].join(' ').strip
        next_total = next_text.length + next_remaining
        next if first_text.length > max_chars || next_total < min_next_size
        score = (max_chars - first_text.length).abs + (min_next_size - next_total).abs
        if score < best_score
          best_score = score
          best_idx = idx
        end
      end
      best_idx
    end

    def self.tokenize_text(text)
      raw = text.to_s.scan(/\p{L}+[\p{L}\p{M}'’\-]*|\d+|[^\p{L}\d\s]+/)
      out = []
      raw.each { |tok| tok.match?(/\A[^\p{L}\d\s]+\z/) && out.any? ? out[-1] << tok : out << tok }
      out
    end

    def self.assign_tokens_to_words!(sent, tokens)
      src_n = sent.words.size
      trg_n = tokens.size
      return sent.words.each_with_index { |w,i| w.word = tokens[i] } if src_n == trg_n
      if trg_n < src_n
        sent.words.each_with_index { |w,i| w.word = i < trg_n ? tokens[i] : "" }
        sent.words.reject! { |w| w.word.to_s.strip.empty? }
      else
        base, extra = trg_n.divmod(src_n)
        sent.words.each_with_index do |w,i|
          offset = i < extra ? i * (base + 1) : (extra * (base + 1)) + ((i - extra) * base)
          count  = i < extra ? base + 1 : base
          w.word = tokens[offset, count].join(' ')
        end
      end
    end

    def self.merge_segments_for_stdsub(mash, max_chars: MAX_SUBTITLE_CHARS, gap_threshold: 1.0)
      segments = mash.segments || []
      return mash if segments.empty?

      merged = []
      current = segments.first
      segments.drop(1).each do |seg|
        gap = seg.start.to_f - current.end.to_f
        combined_len = current.text.to_s.length + 1 + seg.text.to_s.length
        if gap <= gap_threshold && combined_len <= max_chars
          current.text = "#{current.text} #{seg.text}"
          current.end  = seg.end
          current.words ||= []
          current.words.concat(seg.words || [])
        else
          merged << current
          current = seg
        end
      end
      merged << current unless merged.last.equal?(current) rescue merged.push(current)
      mash.segments = merged
      mash
    end

  end
end


