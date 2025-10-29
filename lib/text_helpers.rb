module TextHelpers
  EOS_PUNCT      = /[.!?…]$/
  CLOSERS_ONLY   = /\A["')\]]+\z/
  EOS_WITH_CLOSE = /[.!?…]["')\]]*$/

  def self.normalize_text(str)
    clean = str.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    clean = clean.gsub(/<[^>]+>/, '')
    clean = clean.gsub(/[\u00AD]/, '')
    clean = clean.gsub(/[\u200B\u200C\u200D\u2060\uFEFF]/, '')
    clean = clean.gsub(/[\u0009\u000A\u000B\u000C\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+/u, ' ')
    clean.strip
  end

  # Join an array of line strings from a PDF into one paragraph string using sane defaults
  def self.join_pdf_lines(lines)
    raw = Array(lines).join("\n")
    raw = raw.gsub(/-\s*\n\s*/u, '')
    raw = raw.gsub(/\s*\n\s*/u, ' ')
    normalize_text(raw)
  end

  def self.starts_with_ref_markers?(text)
    text.to_s.strip.match?(/\A\d+[)\.\]]*(?:\s+\d+[)\.\]]*)*/)
  end

  def self.strip_inline_markers(text)
    ids = []
    clean = text.to_s.gsub(/([\p{L}\)\]\.\,;:\"])(\s*)(\d{1,3})(?=(\s|$))/u) do
      ids << $3
      "#{$1}#{$2}"
    end
    [clean, ids]
  end

  def self.split_sentences(text)
    Array(text).join
      .gsub(/([.!?…]"?)(?:\s*\d{1,3})?\s+(?=\p{Lu})/u, "\\1\n")
      .split(/\n+/)
      .map { |s| s.strip }
      .reject(&:empty?)
  end

  def self.heading_line?(text)
    words = text.split(/\s+/)
    return false if words.empty? || words.size > 10
    upper_ratio = words.count { |w| w == w.upcase }.fdiv(words.size)
    return true if upper_ratio > 0.8
    return true if words.all? { |w| w.match?(/\A[A-Z][a-z]+\z/) }
    false
  end

  def self.merge_paragraphs(paragraphs)
    result = []
    paragraphs.each do |para|
      blocks = para[:text].to_s.split(/\n{2,}/).map { |b| normalize_text(b) }.reject(&:empty?)
      blocks.each do |block|
        lines = block.split(/\n+/).map { |l| normalize_text(l) }.reject(&:empty?)
        lines.each do |line|
          if heading_line?(line)
            result << SymMash.new(text: line, page_numbers: para[:page_numbers].dup, merged: false, kind: 'heading')
            next
          end
          if result.any? && result.last[:text] !~ /[\.!?？¡!;:]"?\)?$/ && result.last[:kind] != 'heading'
            result.last[:text] << ' ' << line
            result.last[:page_numbers] |= para[:page_numbers]
            result.last[:merged] = true
          else
            result << SymMash.new(text: line, page_numbers: para[:page_numbers].dup, merged: para[:merged] || false, kind: 'text')
          end
        end
      end
    end
    result
  end

  def self.sentences_from_segments(segments)
    sentences, cur_words, eos_pending = [], [], false
    each_word(segments) do |w|
      raw = w.word.to_s
      next if raw.strip.empty?
      if eos_pending
        if closer_only?(raw)
          attach_closer!(cur_words, w)
          flush_sentence!(sentences, cur_words)
          eos_pending = false
          next
        else
          flush_sentence!(sentences, cur_words)
          eos_pending = false
        end
      end
      cur_words << w
      eos_pending = true if eos_punct?(raw)
    end
    flush_sentence!(sentences, cur_words)
    sentences
  end

  def self.each_word(segments, &block)
    Array(segments).each { |seg| Array(seg.words).each(&block) }
  end

  def self.attach_closer!(cur_words, w)
    last = cur_words.last
    last.word = "#{last.word}#{w.word}"
    last.end  = w.end
  end

  def self.flush_sentence!(sentences, cur_words)
    return if cur_words.empty?
    sentences << SymMash.new(
      text: cur_words.map { |tw| tw.word.to_s.strip }.join(' '),
      start: cur_words.first.start,
      end: cur_words.last.end,
      words: cur_words.dup
    )
    cur_words.clear
  end

  def self.eos_punct?(raw)
    raw.strip.match?(EOS_PUNCT)
  end

  def self.closer_only?(raw)
    raw.match?(CLOSERS_ONLY)
  end

end


