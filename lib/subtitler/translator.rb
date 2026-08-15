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
      source = Array(sent.words)
      tokens = Array(tokens)
      return sent.words = [] if source.empty? || tokens.empty?

      if tokens.size == source.size
        projected = source.zip(tokens).map do |word, token|
          SymMash.new(word.to_h.merge(word: token))
        end
      elsif tokens.size > source.size
        base, extra = tokens.size.divmod(source.size)
        cursor = 0
        projected = source.flat_map.with_index do |word, index|
          count    = base + (index < extra ? 1 : 0)
          duration = word.end.to_f - word.start.to_f
          items    = tokens[cursor, count].map.with_index do |token, token_index|
            start_time = word.start.to_f + duration * token_index / count
            end_time   = token_index == count - 1 ? word.end : word.start.to_f + duration * (token_index + 1) / count
            SymMash.new(word.to_h.merge(word: token, start: start_time, end: end_time))
          end
          cursor += count
          items
        end
      else
        base, extra = source.size.divmod(tokens.size)
        cursor = 0
        projected = tokens.map.with_index do |token, index|
          count  = base + (index < extra ? 1 : 0)
          words  = source[cursor, count]
          cursor += count
          SymMash.new(words.first.to_h.merge(word: token, start: words.first.start, end: words.last.end))
        end
      end

      sent.words = projected
    end
  end
end
