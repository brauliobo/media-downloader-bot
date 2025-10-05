module Audiobook
  module TextHelpers

    def self.normalize_text(str)
      clean = str.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      clean = clean.gsub(/<[^>]+>/, '')
      clean = clean.gsub(/[\u00AD]/, '') # soft hyphen
      clean = clean.gsub(/[\u200B\u200C\u200D\u2060\uFEFF]/, '') # zero-width chars
      clean = clean.gsub(/[\u0009\u000A\u000B\u000C\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+/u, ' ')
      clean.strip
    end

    # Join an array of line strings from a PDF into one paragraph string using sane defaults:
    # - Preserve line boundaries initially, so we can handle hyphen and in-word artifacts
    # - Remove hyphenated wraps ("palavra-\nseguinte" -> "palavraseguinte")
    # - Convert remaining newlines to single spaces
    def self.join_pdf_lines(lines)
      raw = Array(lines).join("\n")
      raw = raw.gsub(/-\s*\n\s*/u, '')
      raw = raw.gsub(/\s*\n\s*/u, ' ')
      normalize_text(raw)
    end

    # Returns true if a text begins with one or more numeric reference markers
    # Examples: "1", "1)", "1 2]", "1 2 3."
    def self.starts_with_ref_markers?(text)
      text.to_s.strip.match?(/\A\d+[)\.\]]*(?:\s+\d+[)\.\]]*)*/)
    end

    # Remove inline numeric markers like "Troyes.1", returns [clean_text, ids]
    def self.strip_inline_markers(text)
      ids = []
      clean = text.to_s.gsub(/([\p{L}\)\]\.,;:\"])(\s*)(\d{1,3})(?=(\s|$))/u) do
        ids << $3
        "#{$1}#{$2}"
      end
      [clean, ids]
    end

    # Split a paragraph into sentences with a simple, diacritic-aware rule
    def self.split_sentences(text)
      Array(text).join
        # Allow footnote markers (e.g., ".1 ") between punctuation and the next sentence
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

  end
end
