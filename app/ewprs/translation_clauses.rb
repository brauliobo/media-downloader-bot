module Ewprs
  # Translation units are cut finer than narration reads: a long contrast or a list of coordinated
  # clauses translates better piece by piece.
  module TranslationClauses
    CONTRAST_BOUNDARY = /(?<=,)\s+(?=but\b)/i
    CONTRAST_MIN_CHARS = 300
    CONTRAST_MIN_COMMAS = 4
    PAIRED_COORDINATION = /\bboth\b[^.!?]*,\s+[^.!?]*,\s+and\b[^.!?]*,/i
    COMMA_BOUNDARY = /(?<=,)\s+/

    module_function

    def split(text, boundary_tokens:, max_chars:)
      pieces = Text::SentenceSplitter.boundaries(text, boundary_tokens: boundary_tokens)
      Text::SentenceSplitter.fit(pieces.flat_map { |sentence| clauses(sentence) }, max_chars)
    end

    def clauses(sentence)
      return sentence.split(COMMA_BOUNDARY) if sentence.match?(PAIRED_COORDINATION)
      return sentence.split(CONTRAST_BOUNDARY) if sentence.length >= CONTRAST_MIN_CHARS || sentence.count(',') >= CONTRAST_MIN_COMMAS

      sentence
    end
  end
end
