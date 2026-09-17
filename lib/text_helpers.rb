require_relative 'ewprs/sentence_splitter'

module TextHelpers
  EOS_PUNCT      = /[.!?…]$/
  EOS_PUNCT_FULL = /[\.!?¡¿；。？！]"?\s*\z/
  CLOSERS_ONLY   = /\A["')\]]+\z/
  EOS_WITH_CLOSE = /[.!?…]["')\]]*$/
  TITLE_ABBREVIATION = /\A(?:Mr|Mrs|Ms|Dr|Prof|Sr|Sra|St)\.\z/i
  # Superscript markers found through glyph geometry are tagged so they survive line joins unambiguously.
  MARKER_TOKEN   = /⟦\d{1,3}⟧/
  MARKER_TAG     = /⟦(\d{1,3})⟧/
  MARKER_LINE    = /\A\d{1,3}[)\].]*(?:\s+\d{1,3}[)\].]*)*\z/
  MARKER_IDS      = /\d{1,3}(?:,\d{1,3})*/
  MARKER_IDS_ONLY = /\A#{MARKER_IDS}\z/
  # A digit before the anchor means a decimal or a thousands separator, not a footnote call; a capital
  # means an acronym or a product name ("MMS1", "CO2").
  MARKER_ANCHOR  = /(?:[\p{Ll}\)\]"”’»]|(?<!\d)[.,;:])/u
  TRAILING_HYPHEN = /\s*[-­‐‑]\z/
  # Leaders run long; a spaced ellipsis in prose stays under six dots.
  TOC_LEADERS     = /(?:\.\s*){6,}|(?:…\s*){3,}/
  # "1. ", "a) " and bullet glyphs open a list entry or a contents line.
  ENUMERATED      = /\A(?:(?:\d{1,3}|\p{Ll})[.)]|[•●○◦▪♦►▶■□➢✔✓✗➤★])\s/u

  def self.reference_marker(ids) = ids.to_s.split(',').map { |id| "⟦#{id}⟧" }.join

  def self.extract_markers(text)
    ids = text.to_s.scan(MARKER_TAG).flatten
    [text.to_s.gsub(MARKER_TAG, ''), ids]
  end

  def self.marker_line?(text) = text.to_s.strip.match?(MARKER_LINE)
  def self.enumerated?(text) = text.to_s.match?(ENUMERATED)
  def self.toc_entry?(text) = text.to_s.match?(TOC_LEADERS)

  # Table-of-contents leaders and the page number they point at are noise when spoken.
  def self.strip_toc_leaders(text)
    return text unless text.to_s.match?(TOC_LEADERS)

    text.gsub(TOC_LEADERS, ' ').gsub(MARKER_TAG, '').sub(/\s+\d{1,4}\s*\z/, '').gsub(/\s+/, ' ').strip
  end

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
    merged = Array(lines).map { |line| normalize_text(line.to_s.sub(/[­‐‑]\z/, '-')) }.reject(&:empty?).reduce(nil) do |text, line|
      next line unless text

      if text.end_with?('-')
        # A hyphen between digits is a range; before a lowercase continuation it splits a word; else a dash.
        next "#{text}#{line}" if text.match?(/\d-\z/) && line.match?(/\A\d/)

        line.match?(/\A\p{Ll}/u) ? "#{text.chomp('-').rstrip}#{line}" : "#{text} #{line}"
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

  def self.strip_inline_markers(text)
    clean, ids = extract_markers(text)
    clean = clean.gsub(/(#{MARKER_ANCHOR})(\d{1,3})(?=\s*:)/u, '\1')
    clean = clean.gsub(/(#{MARKER_ANCHOR})(#{MARKER_IDS})(?=(\s|$))/u) do
      ids.concat($2.split(','))
      $1
    end
    # A call glued to a number is a marker only where the sentence ends; inside it is a decimal.
    clean = clean.sub(/(?<=\d)([.,])(\d{1,3})\z/u) do
      ids << $2
      $1
    end
    [clean, ids]
  end

  def self.split_sentences(text, max_chars: Float::INFINITY)
    parts = Ewprs::SentenceSplitter.split(text, boundary_tokens: MARKER_TOKEN, max_chars: max_chars)

    parts.each_with_object([]) do |part, result|
      if result.any? && result.last.end_with?('.') && Ewprs::SentenceSplitter.abbreviation?(result.last[0..-2])
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

  # "…, Dr." and "the U." have not closed the sentence; the name they introduce is on the next line.
  def self.ends_with_punctuation?(text)
    stripped = text.to_s.strip
    return false unless stripped.match?(EOS_PUNCT_FULL)

    !Ewprs::SentenceSplitter.abbreviation?(stripped.sub(EOS_PUNCT_FULL, ''))
  end

  def self.closer_only?(raw)
    raw.match?(CLOSERS_ONLY)
  end

end
