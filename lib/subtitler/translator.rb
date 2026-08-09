require_relative '../text_helpers'
require_relative 'segments'

class Subtitler
  class Translator

    MAX_SUBTITLE_CHARS = 84
    TRANSLATION_PREFIX = /\A(?:translation|translated(?:\s+text)?|answer|response)\s*:\s*/i

    def self.clean_translation(text)
      text.to_s.strip.sub(TRANSLATION_PREFIX, '').strip
    end

    def self.translate(verbose_json, from:, to:, merge_adjacent: true)
      mash       = SymMash.new(verbose_json)
      sentences  = sentences_for(mash.segments || [])
      texts      = sentences.map(&:text)
      tl_texts   = batch_translate_texts(texts, from: from, to: to)
      apply_translations!(sentences, tl_texts)
      mash.segments = rebuild_segments(sentences)
      split_long_segments!(mash, max_chars: MAX_SUBTITLE_CHARS)
      Segments.merge_adjacent!(mash, max_chars: MAX_SUBTITLE_CHARS) if merge_adjacent
      mash
    end

    def self.batch_size
      defined?(::Translator::BATCH_SIZE) ? ::Translator::BATCH_SIZE : 50
    end

    def self.sentences_for(segs)
      return [] if segs.nil?

      sentences = if segs.any? { |s| Array(s.words).any? }
        TextHelpers.sentences_from_segments(segs)
      else
        segs.flat_map { |segment| text_sentences_for(segment) }
      end

      sentences.select { |sentence| sentence.end.to_f > sentence.start.to_f }
    end

    def self.batch_translate_texts(texts, from:, to:)
      texts.each_slice(batch_size).flat_map do |slice|
        Array(::Translator.translate(slice, from: from, to: to)).map { |text| clean_translation(text) }
      end
    end

    def self.apply_translations!(sentences, tl_texts)
      sentences.zip(tl_texts).each do |sent, ttext|
        sent.text = clean_translation(ttext)
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
      split_items(words, max_chars) { |word| word.word.to_s.strip }
        .map { |chunk| build_segment(seg, chunk) }
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
      parts = split_items(tokens, max_chars) { |token| token }
      return [seg] if parts.size <= 1
      build_text_segments(seg, parts.map { |part| part.join(' ') })
    end

    def self.split_items(items, max_chars, &item_text)
      min_next_size = (max_chars * 0.35).to_i
      buckets = []
      buffer = []
      items.each_with_index do |item, idx|
        sample = join_items(buffer + [item], item_text)
        if sample.length > max_chars && buffer.any?
          next_text = join_items(items[idx..] || [], item_text)
          if next_text.length < min_next_size && buffer.size > 1
            split_idx = find_balanced_split(buffer, max_chars, min_next_size, next_text.length, &item_text)
            if split_idx && split_idx < buffer.size - 1
              buckets << buffer[0..split_idx]
              buffer = buffer[(split_idx + 1)..] + [item]
            else
              buckets << buffer
              buffer = [item]
            end
          else
            buckets << buffer
            buffer = [item]
          end
        else
          buffer << item
        end
      end
      buckets << buffer if buffer.any?
      buckets
    end

    def self.find_balanced_split(buffer, max_chars, min_next_size, next_remaining, &item_text)
      return nil if buffer.size <= 1
      best_idx = nil
      best_score = Float::INFINITY
      (0..buffer.size - 2).each do |idx|
        first_text = join_items(buffer[0..idx], item_text)
        next_text = join_items(buffer[(idx + 1)..], item_text)
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

    def self.join_items(items, item_text)
      items.map { |item| item_text.call(item) }.join(' ').strip
    end

    def self.text_sentences_for(segment)
      text = segment.text.to_s.strip
      return [] if text.empty?

      parts = TextHelpers.split_sentences(text)
      return [SymMash.new(segment.to_h.merge(words: []))] if parts.size <= 1

      build_text_segments(segment, parts)
    end

    def self.build_text_segments(source, texts)
      total    = texts.sum(&:length)
      duration = [source.end.to_f - source.start.to_f, 0].max
      cursor   = source.start.to_f

      texts.map.with_index do |text, idx|
        span = total.zero? ? 0 : duration * text.length.to_f / total
        finish = idx == texts.length - 1 ? source.end : cursor + span
        segment = SymMash.new(source.to_h)
        segment.text  = text
        segment.words = []
        segment.start = cursor
        segment.end   = finish
        cursor        = finish
        segment
      end
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
  end
end
