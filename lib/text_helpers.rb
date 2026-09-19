require_relative 'ewprs/sentence_splitter'

module TextHelpers
  EOS_PUNCT      = /[.!?…]$/
  EOS_PUNCT_FULL = /[\.!?¡¿；。？！]"?\s*\z/
  CLOSERS_ONLY   = /\A["')\]]+\z/
  TITLE_ABBREVIATION = /\A(?:Mr|Mrs|Ms|Dr|Prof|Sr|Sra|St)\.\z/i
  # Superscript markers found through glyph geometry are tagged so they survive line joins unambiguously.
  MARKER_TOKEN   = /⟦\d{1,3}⟧/
  MARKER_TAG     = /⟦(\d{1,3})⟧/
  MARKER_LINE    = /\A\d{1,3}[)\].]*(?:\s+\d{1,3}[)\].]*)*\z/
  # Footnotes number from one, so a raised zero is a percent sign or a degree mark the text
  # layer failed to map rather than a call.
  MARKER_IDS      = /[1-9]\d{0,2}(?:,[1-9]\d{0,2})*/
  MARKER_IDS_ONLY = /\A#{MARKER_IDS}\z/
  # A digit before the anchor means a decimal or a thousands separator, not a footnote call; a capital
  # means an acronym or a product name ("MMS1", "CO2"). A closing quote or bracket only counts where
  # it closes something, and a letter only where it ends a word: a lone letter is a glyph the text
  # layer mapped wrong ("décadas de f950" for 1950).
  MARKER_ANCHOR  = /(?:(?<=\p{L})\p{Ll}|(?<=[\p{L}\p{N}.,;:!?…])[\)\]"”’»]|(?<!\d)[.,;:]|[?!…])/u
  # A text layer that lost a space glues a cross-reference to the word introducing it,
  # "página278". That number points at a page, so it is never a call.
  PAGE_REFERENCE  = /\b(p(?:á|a)g(?:ina)?s?\.?|pages?)(\d{1,4})\b/iu
  TRAILING_HYPHEN = /\s*[-­‐‑]\z/
  # An ellipsis is a pause; whether it closes the sentence depends on what follows.
  TRAILING_ELLIPSIS = /(?:\.{3}|…)["”’)\]»]*\s*\z/u
  # Leaders run long; a spaced ellipsis in prose stays under six dots.
  TOC_LEADERS     = /(?:\.\s*){6,}|(?:…\s*){3,}/
  BULLETS         = '•●○◦▪♦►▶■□➢✔✓✗➤★'
  # "1. ", "a) " and bullet glyphs open a list entry or a contents line.
  ENUMERATED      = /\A(?:(?:\d{1,3}|\p{Ll})[.)]|[#{BULLETS}])\s/u
  # The glyph marks the entry for the detector; it says nothing once the text is spoken.
  BULLET_GLYPH    = /\A((?:\d{1,3}|\p{Ll})[.)]+\s*)?[#{BULLETS}]\s*/u

  def self.reference_marker(ids) = ids.to_s.split(',').map { |id| "⟦#{id}⟧" }.join

  def self.extract_markers(text)
    ids = text.to_s.scan(MARKER_TAG).flatten
    [text.to_s.gsub(MARKER_TAG, ''), ids]
  end

  def self.marker_line?(text) = text.to_s.strip.match?(MARKER_LINE)
  def self.enumerated?(text) = text.to_s.match?(ENUMERATED)
  def self.toc_entry?(text) = text.to_s.match?(TOC_LEADERS)
  def self.bulleted?(text) = text.to_s.match?(BULLET_GLYPH)
  def self.ends_with_ellipsis?(text) = text.to_s.match?(TRAILING_ELLIPSIS)

  # Two lines say the same thing when they read the same; a folio differs only in its digits.
  def self.comparable(text) = text.to_s.downcase.gsub(/\s+/, ' ').strip
  def self.comparable_key(text) = comparable(text).gsub(/\d+/, '<d>')
  def self.strip_bullet(text) = text.to_s.sub(BULLET_GLYPH) { $1.to_s }

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

  # Spelled out, a URL is a minute of letters and slashes. Its host is the part a listener can
  # do anything with, so that is what is said.
  URL = %r{\b(?:https?://|www\.)([^\s/?\#]+)\S*}i

  def self.spoken_urls(text) = text.to_s.gsub(URL) { Regexp.last_match(1).sub(/\Awww\./i, '') }

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
    clean = clean.gsub(PAGE_REFERENCE) { "#{$1} #{$2}" }
    clean = clean.gsub(/(#{MARKER_ANCHOR})(\d{1,3})(?=\s*:)/u, '\1')
    clean = clean.gsub(/(#{MARKER_ANCHOR})(#{MARKER_IDS})(?=(\s|$))/u) do
      ids.concat($2.split(','))
      $1
    end
    # A call glued to a number is a marker only where the sentence ends; inside it is a decimal,
    # and a group of exactly three digits is a thousands separator wherever it sits.
    clean = clean.sub(/(?<=\d)([.,])(\d{1,2})\z/u) do
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

  # A short line set in title case or in capitals reads as a heading. An attribution, a rights
  # line and a leftover drop cap never do, however short they are.
  NEVER_HEADING      = /\A(?:[—–]|©|\(c\)\s|\p{L}\z)/u
  HEADING_MAX_WORDS  = 10
  HEADING_CAPS_RATIO = 0.6

  def self.heading_like?(text)
    text = text.to_s.strip
    return false if text.match?(/\A[^\p{L}]*\z/u) || text.match?(NEVER_HEADING)

    words = text.split(/\s+/)
    return false if words.empty? || words.size > HEADING_MAX_WORDS
    return true if words.size <= 3 && text.match?(/\A\p{Lu}/u) && !text.match?(/[.!?…,;:]\z/)
    return true if words.count { |word| word == word.upcase && word.length > 1 }.fdiv(words.size) > HEADING_CAPS_RATIO

    words.all? { |word| word.match?(/\A[A-Z]/) } && !text.match?(/[.!?]\z/)
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
