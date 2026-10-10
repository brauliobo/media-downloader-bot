module Audiobook
  module Punctuation
    CLOSING = /[\.!?¡¿；。？！]"?\s*\z/
    # An ellipsis is a pause; whether it closes the sentence depends on what follows.
    ELLIPSIS = /(?:\.{3}|…)["”’)\]»]*\s*\z/u

    module_function

    # "…, Dr." and "the U." have not closed the sentence; the name they introduce is on the next line.
    def closes?(text)
      stripped = text.to_s.strip
      return false unless stripped.match?(CLOSING)

      !::Ewprs::SentenceSplitter.abbreviation?(stripped.sub(CLOSING, ''))
    end

    def ellipsis?(text) = text.to_s.match?(ELLIPSIS)
  end
end
