module Text
  module Punctuation
    CLOSING  = /[\.!?¡¿；。？！]"?\s*\z/
    # An ellipsis is a pause; whether it closes the sentence depends on what follows.
    ELLIPSIS = /(?:\.{3}|…)["”’)\]»]*\s*\z/u
    TERMINAL = /[.!?…]["”’)\]»]*\z/u
    CLAUSE   = /[.!?…,;:]["”’)\]»]*\z/u
    ONLY     = /\A[\p{P}\p{S}\s]+\z/u

    module_function

    # "…, Dr." and "the U." have not closed the sentence; the name they introduce is on the next line.
    def closes?(text)
      stripped = text.to_s.strip
      return false unless stripped.match?(CLOSING)

      !SentenceSplitter.abbreviation?(stripped.sub(CLOSING, ''))
    end

    def ellipsis?(text) = text.to_s.match?(ELLIPSIS)
    def terminal?(text) = text.to_s.match?(TERMINAL)
    def clause_end?(text) = text.to_s.match?(CLAUSE)
    def only?(text) = text.to_s.match?(ONLY)
  end
end
