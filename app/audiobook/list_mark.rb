module Audiobook
  # "1. ", "a) " and bullet glyphs open a list entry or a contents line.
  module ListMark
    BULLETS    = '•●○◦▪♦►▶■□➢✔✓✗➤★'
    ENUMERATED = /\A(?:(?:\d{1,3}|\p{Ll})[.)]|[#{BULLETS}])\s/u
    # The glyph marks the entry for the detector; it says nothing once the text is spoken.
    BULLET     = /\A((?:\d{1,3}|\p{Ll})[.)]+\s*)?[#{BULLETS}]\s*/u

    module_function

    def enumerated?(text) = text.to_s.match?(ENUMERATED)
    def bulleted?(text) = text.to_s.match?(BULLET)
    def strip_bullet(text) = text.to_s.sub(BULLET) { $1.to_s }
  end
end
