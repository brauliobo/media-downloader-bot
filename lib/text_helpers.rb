require_relative 'ewprs/sentence_splitter'

module TextHelpers
  EOS_PUNCT      = /[.!?…]$/
  EOS_PUNCT_FULL = /[\.!?¡¿；。？！]"?$/
  CLOSERS_ONLY   = /\A["')\]]+\z/
  EOS_WITH_CLOSE = /[.!?…]["')\]]*$/
  TITLE_ABBREVIATION = /\A(?:Mr|Mrs|Ms|Dr|Prof|Sr|Sra|St)\.\z/i

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
    merged = Array(lines).map { |line| normalize_text(line) }.reject(&:empty?).reduce(nil) do |text, line|
      next line unless text

      if text.end_with?('-')
        "#{text.chomp('-')}#{line}"
      else
        overlap = overlapping_word_count(text, line)
        words = line.split(/\s+/).drop(overlap)
        [text, words.join(' ')].reject(&:empty?).join(' ')
      end
    end

    normalize_text(merged)
  end

  def self.overlapping_word_count(left, right)
    left_words = overlap_words(left)
    right_words = overlap_words(right)
    max = [left_words.size, right_words.size, 8].min

    max.downto(2) do |count|
      return count if left_words.last(count) == right_words.first(count)
    end

    return 1 if left_words.last && left_words.last == right_words.first && left_words.last.length >= 6

    0
  end

  def self.overlap_words(text)
    text.to_s.split(/\s+/)
      .map { |word| word.downcase.gsub(/\A[^\p{L}\p{N}]+|[^\p{L}\p{N}]+\z/u, '') }
      .reject(&:empty?)
  end

  def self.starts_with_ref_markers?(text)
    text.to_s.strip.match?(/\A\d+[)\.\]]*(?:\s+\d+[)\.\]]*)*/)
  end

  def self.strip_inline_markers(text)
    ids = []
    clean = text.to_s.gsub(/([\p{L}\)\]\.\,;:\"])(\d{1,3})(?=\s*:)/u, '\1')
    clean = clean.gsub(/([\p{L}\)\]\.\,;:\"])(\d{1,3})(?=(\s|$))/u) do
      ids << $2
      $1
    end
    [clean, ids]
  end

  def self.split_sentences(text, max_chars: Float::INFINITY)
    parts = Ewprs::SentenceSplitter.split(text, max_chars: max_chars)

    parts.each_with_object([]) do |part, result|
      if result.any? && result.last.match?(/\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Sra|St)\.$/i)
        result[-1] = "#{result[-1]} #{part}"
      else
        result << part
      end
    end
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

  def self.sentences_from_entries(entries)
    unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Subtitler::Subtitle::Entry) }
      raise TypeError, 'entries must contain only Subtitler::Subtitle::Entry objects'
    end

    sentences, cur_words, eos_pending = [], [], false
    each_subtitle_word(entries) do |word|
      raw = word.text
      next if raw.strip.empty?
      if eos_pending
        if closer_only?(raw)
          attach_closer!(cur_words, word)
          flush_sentence!(sentences, cur_words)
          eos_pending = false
          next
        else
          flush_sentence!(sentences, cur_words)
          eos_pending = false
        end
      end
      cur_words << word
      eos_pending = true if eos_punct?(raw) && !title_abbreviation?(raw)
    end
    flush_sentence!(sentences, cur_words)
    sentences
  end

  def self.each_subtitle_word(entries, &block)
    entries.each { |entry| entry.words.each { |word| block.call(word.deep_copy) } }
  end

  def self.attach_closer!(cur_words, word)
    cur_words.last.merge!(word)
  end

  def self.flush_sentence!(sentences, cur_words)
    return if cur_words.empty?
    sentences << Subtitler::Subtitle::Entry.new(
      text: cur_words.map { |word| word.text.strip }.join(' '),
      start: cur_words.first.start,
      finish: cur_words.last.finish,
      words: cur_words.dup
    )
    cur_words.clear
  end

  def self.eos_punct?(raw)
    raw.strip.match?(EOS_PUNCT)
  end

  def self.title_abbreviation?(raw)
    raw.strip.match?(TITLE_ABBREVIATION)
  end

  def self.ends_with_punctuation?(text)
    text.to_s.strip.match?(EOS_PUNCT_FULL)
  end

  def self.closer_only?(raw)
    raw.match?(CLOSERS_ONLY)
  end

end
