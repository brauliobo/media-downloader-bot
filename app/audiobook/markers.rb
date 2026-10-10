module Audiobook
  # Footnote calls ("troyes.1", superscripts found through glyph geometry) travel inside the text as
  # tagged markers until the note they point at is attached.
  module Markers
    # Superscript markers found through glyph geometry are tagged so they survive line joins unambiguously.
    TOKEN = /⟦\d{1,3}⟧/
    TAG   = /⟦(\d{1,3})⟧/
    LINE  = /\A\d{1,3}[)\].]*(?:\s+\d{1,3}[)\].]*)*\z/
    # Footnotes number from one, so a raised zero is a percent sign or a degree mark the text
    # layer failed to map rather than a call.
    IDS      = /[1-9]\d{0,2}(?:,[1-9]\d{0,2})*/
    IDS_ONLY = /\A#{IDS}\z/
    # A digit before the anchor means a decimal or a thousands separator, not a footnote call; a capital
    # means an acronym or a product name ("MMS1", "CO2"). A closing quote or bracket only counts where
    # it closes something, and a letter only where it ends a word: a lone letter is a glyph the text
    # layer mapped wrong ("décadas de f950" for 1950).
    ANCHOR = /(?:(?<=\p{L})\p{Ll}|(?<=[\p{L}\p{N}.,;:!?…])[\)\]"”’»]|(?<!\d)[.,;:]|[?!…])/u
    # A text layer that lost a space glues a cross-reference to the word introducing it,
    # "página278". That number points at a page, so it is never a call.
    PAGE_REFERENCE = /\b(p(?:á|a)g(?:ina)?s?\.?|pages?)(\d{1,4})\b/iu

    module_function

    def wrap(ids) = ids.to_s.split(',').map { |id| "⟦#{id}⟧" }.join

    def extract(text)
      ids = text.to_s.scan(TAG).flatten
      [text.to_s.gsub(TAG, ''), ids]
    end

    def line?(text) = text.to_s.strip.match?(LINE)

    def strip_inline(text)
      clean, ids = extract(text)
      clean = clean.gsub(PAGE_REFERENCE) { "#{$1} #{$2}" }
      clean = clean.gsub(/(#{ANCHOR})(\d{1,3})(?=\s*:)/u, '\1')
      clean = clean.gsub(/(#{ANCHOR})(#{IDS})(?=(\s|$))/u) do
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
  end
end
