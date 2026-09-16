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
    # "1. Heading" opens a numbered section; the number is a label, not a sentence.
    ENUMERATOR = /\A\d{1,3}\z/
    NO_BOUNDARY_TOKENS = /(?!)\z/
    # A digit right after the period is a footnote marker when a word precedes it, a decimal otherwise.
    SENTENCE_END = '(?:[.!?…](?!\d)|(?<=\p{L})[.!?…](?=\d{1,3}(?:\s|\z))|[。！？])'
    CLOSING_QUOTES = '["”’」』】）]*'
    CJK_CHARACTER = '[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]'

    module_function

    def split(text, boundary_tokens: NO_BOUNDARY_TOKENS, max_chars: Float::INFINITY, clauses: false)
      transparent = "(?:#{boundary_tokens.source})*"
      boundary = %r{
        (#{SENTENCE_END}#{CLOSING_QUOTES})(\s*\d{1,3})?(#{transparent})
        (?:
          \s+(?=#{transparent}(?:(?:\[\[?|#{OPENING_QUOTE})?\p{Lu}|\())
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
        chunks = chunks.flat_map do |chunk|
          chunk.length > max_chars ? chunk.split(boundary) : chunk
        end
      end
      chunks.flat_map { |chunk| split_words(chunk, max_chars) }
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
