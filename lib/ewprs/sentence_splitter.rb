module Ewprs
  module SentenceSplitter
    CONTRAST_BOUNDARY = /(?<=,)\s+(?=but\b)/i
    CONTRAST_MIN_CHARS = 300
    OPENING_QUOTE = /(?:&(?:ldquo|lsquo|quot);|["“‘])/

    module_function

    def split(text, boundary_tokens:, max_chars:)
      transparent = "(?:#{boundary_tokens.source})*"
      boundary = /([.!?…]"?)(\s*\d{1,3})?(#{transparent})\s+(?=#{transparent}(?:\[\[?|#{OPENING_QUOTE})?\p{Lu})/u
      sentences = Array(text).join
        .gsub(/(?<=&#8230;)\s+/i, "\n")
        .gsub(boundary, "\\1\\2\\3\n")
        .split(/\n+/)
        .map(&:strip)
        .reject(&:empty?)
        .flat_map do |sentence|
          if sentence.length >= CONTRAST_MIN_CHARS
            sentence.split(CONTRAST_BOUNDARY)
          else
            sentence
          end
        end

      sentences.flat_map { |sentence| split_long(sentence, max_chars) }
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
        return [text] unless boundary

        chunks << remaining[0...boundary].rstrip
        remaining = remaining[boundary..].lstrip
      end
      chunks << remaining unless remaining.empty?
      chunks
    end
  end
end
