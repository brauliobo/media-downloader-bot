module Ewprs
  module SentenceSplitter
    CONTRAST_BOUNDARY = /(?<=,)\s+(?=but\b)/i
    CONTRAST_MIN_CHARS = 300
    CONTRAST_MIN_COMMAS = 4
    PAIRED_COORDINATION = /\bboth\b[^.!?]*,\s+[^.!?]*,\s+and\b[^.!?]*,/i
    COMMA_BOUNDARY = /(?<=,)\s+/
    OPENING_QUOTE = /(?:&(?:ldquo|lsquo|quot);|["“‘])/
    HONORIFIC_ABBREVIATION = /\b(?:Dr|Dra|Mr|Mrs|Ms|Prof|Profa|Sr|Sra|Srta|St|Sto|Sta|Av|art|cap|cf|ed|fig|pp|vol|séc|sec)\z/i
    # "Roger L. Cole" and "the U. S." keep single-letter initials attached to the name that follows.
    INITIAL_ABBREVIATION = /(?:\A|[^\p{L}])\p{Lu}\z/u
    # "Chapter XIV. Title" names a part; the numeral does not close a sentence.
    NUMERAL_ABBREVIATION = /(?:\A|[^\p{L}])[IVX]{2,4}\z/
    # "1. Heading" and "a. item" open an enumerated entry; the label closes nothing.
    ENUMERATOR = /(?:\A|[.!?…]["”’)\]»]*\s+)(?:\d{1,3}|\p{Ll})\z/u
    ENUMERATED_START = '(?:\d{1,3}|\p{Ll})[.)]\s'
    NO_BOUNDARY_TOKENS = /(?!)\z/
    MARKER_RUN = '\d{1,3}(?:,\d{1,3})*'
    # Digits right after the period are footnote markers when a word precedes them, a decimal otherwise.
    SENTENCE_END = "(?:[.!?…](?!\\d)|(?<=\\p{L})[.!?…](?=#{MARKER_RUN}(?:\\s|\\z))|[。！？])"
    CLOSING_QUOTES = '["”’」』】）]*'
    CJK_CHARACTER = '[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]'

    module_function

    def split(text, boundary_tokens: NO_BOUNDARY_TOKENS, max_chars: Float::INFINITY, clauses: false)
      transparent = "(?:#{boundary_tokens.source})*"
      boundary = %r{
        (#{SENTENCE_END}#{CLOSING_QUOTES})(\s*#{MARKER_RUN})?(#{transparent})
        (?:
          \s+(?=#{transparent}(?:(?:\[\[?|#{OPENING_QUOTE})?\p{Lu}|\(|#{ENUMERATED_START}))
          |\s*(?=#{transparent}(?:#{OPENING_QUOTE})?#{CJK_CHARACTER})
        )
      }ux
      sentences = Array(text).join
        .gsub(/(?<=&#8230;)\s+/i, "\n")
        .gsub(boundary) do |match|
          if abbreviation?(Regexp.last_match.pre_match)
            match
          else
            "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{Regexp.last_match(3)}\n"
          end
        end
        .split(/\n+/)
        .map(&:strip)
        .reject(&:empty?)
        .flat_map { |sentence| clauses ? split_clauses(sentence) : sentence }

      sentences.flat_map { |sentence| split_long(sentence, max_chars) }
    end

    # A period left at the end of a piece that is an abbreviation closed nothing; the next piece continues it.
    def sentences(text, **options)
      split(text, **options).each_with_object([]) do |part, result|
        if result.last&.end_with?('.') && abbreviation?(result.last[0..-2])
          result[-1] = "#{result[-1]} #{part}"
        else
          result << part
        end
      end
    end

    def abbreviation?(prefix)
      prefix.match?(HONORIFIC_ABBREVIATION) || prefix.match?(INITIAL_ABBREVIATION) ||
        prefix.match?(NUMERAL_ABBREVIATION) || prefix.match?(ENUMERATOR)
    end

    # Clause splitting builds translation units; narration keeps the sentence whole.
    def split_clauses(sentence)
      return sentence.split(COMMA_BOUNDARY) if sentence.match?(PAIRED_COORDINATION)
      return sentence.split(CONTRAST_BOUNDARY) if sentence.length >= CONTRAST_MIN_CHARS || sentence.count(',') >= CONTRAST_MIN_COMMAS

      sentence
    end

    def split_long(sentence, max_chars)
      return [sentence] if sentence.length <= max_chars

      chunks = [sentence]
      [/(?<=[;:])\s+/, /(?<=,)\s+/].each do |boundary|
        chunks = chunks.flat_map { |chunk| chunk.length > max_chars ? pack(chunk.split(boundary), max_chars) : chunk }
      end
      chunks.flat_map { |chunk| split_words(chunk, max_chars) }
    end

    # Clause pieces are glued back up to the limit so a long list is not read one item at a time.
    def pack(pieces, max_chars)
      pieces.each_with_object([]) do |piece, packed|
        if packed.any? && packed.last.length + piece.length < max_chars
          packed[-1] = "#{packed.last} #{piece}"
        else
          packed << piece
        end
      end
    end

    def split_words(text, max_chars)
      chunks = []
      remaining = text
      while remaining.length > max_chars
        boundary = remaining.rindex(/\s+/, max_chars) || remaining.index(/\s+/, max_chars)
        return remaining.scan(/.{1,#{max_chars}}/m) if !boundary && remaining.match?(/#{CJK_CHARACTER}/u)
        return [text] unless boundary

        chunks << remaining[0...boundary].rstrip
        remaining = remaining[boundary..].lstrip
      end
      chunks << remaining unless remaining.empty?
      chunks
    end
  end
end
