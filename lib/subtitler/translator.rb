require_relative '../text_helpers'

class Subtitler
  class Translator

    def self.translate(verbose_json, from:, to:)
      mash       = SymMash.new(verbose_json)
      sentences  = sentences_for(mash.segments || [])
      texts      = sentences.map(&:text)
      tl_texts   = batch_translate_texts(texts, from: from, to: to)
      apply_translations!(sentences, tl_texts)
      mash.segments = rebuild_segments(sentences)
      merge_segments_for_stdsub(mash)
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

    def self.merge_segments_for_stdsub(mash, max_chars: 84, gap_threshold: 1.0)
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


