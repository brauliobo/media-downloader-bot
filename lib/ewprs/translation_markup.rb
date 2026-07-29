module Ewprs
  module TranslationMarkup
    CONTENT_CLASSES = %w[
      Para_Major_Heading Para_Minor_Heading Para_Indent plain Para_Sloka
      Para_Translation_Eds Para_Citation Para_Quote Para_Footnote center
    ].freeze
    WINDOWS_CONTROLS = {
      "\u0085" => '...', "\u0091" => "'", "\u0092" => "'",
      "\u0093" => '"', "\u0094" => '"', "\u0096" => '-', "\u0097" => '--'
    }.freeze

    PROTECTED_ELEMENT = %r{
      <(?<tag>script|style)\b[^>]*>.*?</\k<tag>\s*>|
      <p\b(?=[^>]*\bclass\s*=\s*["']?Para_Sloka\b)[^>]*>.*?</p\s*>|
      <span\b(?=[^>]*\bclass\s*=\s*["']?Bengali\b)[^>]*>.*?</span\s*>
    }mix
    BLOCK_CONTENT = /(<!--\s*block\b[^>]*\btype=(?:paragraph|title)\b[^>]*-->)(.*?)(<!--\s*\/block\s*-->)/mi
    GROUPED_PARAGRAPH = %r{
      (<p\b(?=[^>]*\bclass\s*=\s*["']?(?:Para_Notes|Para_Footnote)\b)[^>]*>)
      (.*?)
      (</p\s*>)
    }mix
    GROUPED_DIV = %r{
      (<div\b(?=[^>]*\bclass\s*=\s*["']?(?:discourse_title|book_title|book_contents|book_chapter_title)\b)[^>]*>)
      (.*?)
      (</div\s*>)
    }mix
    EMPTY_INLINE_ELEMENT = Regexp.union(
      %w[i em b strong span u sup sub].map { |tag| /<#{tag}\b[^>]*>\s*<\/#{tag}\s*>/i }
    )
    FOOTNOTE          = /<!--\s*fn\s*-->.*?<!--\s*\/fn\s*-->/mi
    EDITORIAL_CONTENT = /\[\[?[^\[\]\r\n]+\]\]?/
    HYPHENATED_EDITORIAL = /(?<prefix>\b[A-Za-z][A-Za-z'’-]*)-(?<editorial>#{EDITORIAL_CONTENT})/
    ATTACHED_EDITORIAL = /(?<prefix>\b[A-Za-z][A-Za-z'’-]*)(?<editorial>#{EDITORIAL_CONTENT})/
    STRUCTURAL_MARKUP = %r{#{FOOTNOTE}|#{EMPTY_INLINE_ELEMENT}|<br\s*/?>|</?(?:table|thead|tbody|tfoot|tr|td|th|ul|ol|li)\b[^>]*>}i
    TEXT_NODE        = /(?<=>)([^<]+)(?=<)/m
    MARKED_WORD      = /(?<![A-Za-z])(?:[A-Za-z][A-Za-z'’-]*)(?:(?:&#x(?:301|32D);)[A-Za-z'’-]*)+(?![A-Za-z])/i
    ASCII_TRANSLITERATED_WORD = /(?<![A-Za-z])[A-Za-z]*(?:aa|ii|uu)[A-Za-z]*(?![A-Za-z])/i
    PROPER_NOUN_GLOSS = %r{
      (?<prefix>\b(?i:at|from|in|near|of)\s+)
      (?<term>(?<![A-Za-z])[A-Z][a-z][A-Za-z'’-]*(?![A-Za-z]))(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }x
    MARKED_INLINE    = %r{<(?<tag>i|em)\b[^>]*>\s*#{MARKED_WORD}[;,]?\s*</\k<tag>\s*>}i
    FOREIGN_INLINE   = %r{<(?<tag>i|em)\b[^>]*>(?<content>.*?)</\k<tag>\s*>}mi
    MARKED_INLINE_GLOSS = %r{
      (?<term><(?<tag>i|em)\b[^>]*>(?=[^<]*[A-Za-z])[^<]*</\k<tag>>)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }ix
    INLINE_PARENTHETICAL_GLOSS = %r{
      (?<term><(?<tag>i|em)\b[^>]*>(?<content>[^<]+)</\k<tag>>)(?<spacing>\s*)
      \((?<gloss>[^()\r\n]+)\)
    }ix
    MARKED_PHRASE_GLOSS = %r{
      (?<term>#{MARKED_WORD}(?:\s+(?:#{MARKED_WORD}|[A-Za-z][A-Za-z'’-]*)){1,6})(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }ix
    CONSONANT_TERM_GLOSS = %r{
      (?<term>(?<![A-Za-z])(?=[a-z]{2,4}(?![A-Za-z]))[b-df-hj-np-tv-z]+)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }x
    DEFINED_TERM_GLOSS = %r{
      (?<term>(?<=\bmeans\s)[a-z][a-z'’-]*)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }ix
    HYPHENATED_TERM_GLOSS = %r{
      (?<term>(?<![A-Za-z])[A-Za-z][A-Za-z'’]*(?:-[A-Za-z][A-Za-z'’]*)+)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }x
    ASCII_PHRASE_PARENTHETICAL_GLOSS = %r{
      (?<term>#{ASCII_TRANSLITERATED_WORD}(?:\s+[A-Za-z][A-Za-z'’-]*){1,6})(?<spacing>\s*)
      (?<opening>\()(?<gloss>[^()\r\n]+)(?<closing>\))
    }ix
    QUOTED_GLOSS = %r{
      (?<term>&(?:rdquo|quot);)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }ix
    NAMED_MARKED_GROUP = %r{
      (?<prefix>\b(?i:of)\s+)
      (?<name>(?<![A-Za-z])[A-Z][A-Za-z'’-]*(?![A-Za-z]))\s+(?<group>#{MARKED_WORD})
    }x
    GLOSS_TERM = /(?:#{MARKED_WORD}|(?<![A-Za-z])[A-Za-z][A-Za-z'’-]*(?![A-Za-z]))/
    PARENTHETICAL_GLOSS = %r{
      (?<term>#{GLOSS_TERM})(?<spacing>\s*)\((?<gloss>[^()\r\n]+)\)
    }ix
    COORDINATED_PARENTHETICAL_GLOSSES = %r{
      #{GLOSS_TERM}\s*\([^()\r\n]+\)
      (?:(?:\s*,\s*|\s+(?:and|or)\s+)#{GLOSS_TERM}\s*\([^()\r\n]+\))+
    }ix
    FORMULA_PARENTHETICAL_GLOSSES = %r{
      #{GLOSS_TERM}\s*\([^()\r\n]+\)
      (?:(?:\s*(?:&ndash;|[+=])\s*)#{GLOSS_TERM}\s*\([^()\r\n]+\))+
    }ix
    PARENTHETICAL_GLOSS_LIST = Regexp.union(
      COORDINATED_PARENTHETICAL_GLOSSES, FORMULA_PARENTHETICAL_GLOSSES
    )
    COORDINATED_TERMS_PARENTHETICAL_GLOSS = %r{
      (?<terms>#{GLOSS_TERM}(?:(?:\s*,\s*|\s+(?:and|or)\s+)#{GLOSS_TERM})+)(?<spacing>\s*)
      \((?<gloss>[^()\r\n]+)\)
    }ix
    COORDINATED_BRACKETED_GLOSSES = %r{
      (?<first_term>#{MARKED_WORD})(?<first_spacing>\s*)
      (?<first_opening>\[\[?)(?<first_gloss>[^\[\]\r\n]+)(?<first_closing>\]\]?)
      (?<coordination>\s+(?:and|or)\s+(?:an?\s+)?)
      (?<second_term>#{GLOSS_TERM})(?<second_spacing>\s*)
      (?<second_opening>\[\[?)(?<second_gloss>[^\[\]\r\n]+)(?<second_closing>\]\]?)
    }ix
    COORDINATED_WITH_GLOSSES = %r{
      (?<prefix>\bwith\s+)(?<first_term>#{GLOSS_TERM})(?<first_spacing>\s*)
      (?<first_opening>\[\[?)(?<first_gloss>[^\[\]\r\n]+)(?<first_closing>\]\]?)
      (?<coordination>\s+nor\s+with\s+)
      (?<second_term>#{GLOSS_TERM})(?<second_spacing>\s*)
      (?<second_opening>\[\[?)(?<second_gloss>[^\[\]\r\n]+)(?<second_closing>\]\]?)
    }ix
    EDITORIAL_BRACKET = /\[\[?|\]\]?/
    EDITORIAL_TAG = %r{<span data-ewprs="[12][12]">|</span>}i
    PAIRED_DELIMITER  = /[()\[\]{}]/
    PARENTHETICAL_CONTENT = /\((?<content>[^()\r\n]+)\)/
    INLINE_ORIGINAL  = %r{
      (?:
        (?<=,\s)
        (?=(?:[A-Za-z]+\s+)?#{MARKED_WORD})[^<>.!?\r\n]+?[.!?]?
        \s+(?=\[(?:&(?:ldquo|quot);|["“]))
      |
        (?<=\b(?-i:And)\s)
        (?=(?:[A-Za-z]+\s+)?#{MARKED_WORD})[^<>.!?\r\n]+?[.!?]?
        \s+(?=\[(?:&(?:ldquo|quot);|["“]|(?=(?-i:[A-Z]))))
      )
    }ix
    BIBLIOGRAPHIC_TITLE = /(?<=\bsee\s)[A-Z][^,.;\r\n]+(?=,\s*\d{4}\b)/
    AUTHORED_CITATION_TITLE = %r{
      (?<=,\s)[A-Z][A-Za-z'’-]*
      (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|with|[A-Z][A-Za-z'’-]*)){2,}
      (?=,\s*\d{4}\b)
    }x
    PARTED_PUBLICATION_TITLE = %r{
      (?<=\bpublication\sin\s)[A-Z][^,.\r\n]+(?=,\s*Part\s+\d+,\s*\d{4}\b)
    }ix
    DATED_PUBLICATION_TITLE = %r{
      (?<=\bpublication\sin\s)[A-Z][^,.\r\n]+(?=,\s*\d{4}\b)
    }ix
    NUMBERED_SERIES_TITLE = %r{
      (?<=\bin\s)[A-Z][A-Za-z'’-]*(?:\s+(?:[a-z]{1,4}|[A-Z][A-Za-z'’-]*)){2,}
      (?=\s+\d+,\s*\d{4}\b)
    }x
    ITALIC_CITATION_TITLE = %r{
      <(?<tag>i|em)\b[^>]*>[^<>]+</\k<tag>\s*>
      (?=\s*,?\s*(?:\d{4}\b|(?:\d+(?:st|nd|rd|th)|[A-Z][a-z]+)\s+edition\b))
    }ix
    ITALIC_PART_TITLE = %r{
      <(?<tag>i|em)\b[^>]*>(?=[^<>]*\bPart\s+\d+\b)[^<>]+</\k<tag>\s*>
    }ix
    IN_DATED_CITATION_TITLE = %r{
      (?<=\b(?i:in)\s)
      [A-Z](?:&(?:\#x[\dA-Fa-f]+|\#\d+|[A-Za-z]+);|[A-Za-z0-9'’ -])+
      (?=,\s*\d{4}\b)
    }x
    NUMBERED_PUBLICATION_CITATION_TITLE = %r{
      [A-Z][A-Za-z'’-]*
      (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|with|[A-Z][A-Za-z'’-]*)){1,}
      \s+(?:Part|Volume)\s+\d+
      (?=,\s*\d{4}\b)
    }x
    ITALIC_EDITION_TITLE = %r{
      (?<=\bEdition\sof\s)<(?<tag>i|em)\b[^>]*>[^<>]+</\k<tag>\s*>
    }ix
    BOOK_TITLE = %r{
      (?<=\bbook\s)[A-Z][A-Za-z'’-]*
      (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|[A-Z][A-Za-z'’-]*)){2,}
      (?=[.,]|\z)
    }x
    SEE_PARENTHETICAL_TITLE = %r{
      (?<=\bSee\sespecially\s)[A-Z][A-Za-z'’-]*
      (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|[A-Z][A-Za-z'’-]*)){2,}
      (?=\s+\(\d{4}\))
    }x
    EDITIONED_TITLE = %r{
      (?<=\bin\s)[A-Z][A-Za-z'’-]*
      (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|[A-Z][A-Za-z'’-]*)){2,}
      (?=,\s*\d+(?:st|nd|rd|th)\s+edition\b)
    }x
    PRINTED_EDITION_TITLE = %r{
      (?<=\bprinted\s)[A-Z][A-Za-z'’-]*
      (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|[A-Z][A-Za-z'’-]*)){2,}
      (?=,\s*\d+(?:st|nd|rd|th)\s+edition\b)
    }x
    VOLUME_CITATION_TITLE = %r{
      (?<=\bin\s)[A-Z](?:&(?:\#x[\dA-Fa-f]+|\#\d+|[A-Za-z]+);|[^,.;\r\n])+
      (?=\s+(?i:Vol(?:ume)?\.?)\s*\d+\b)
    }x
    PUBLICATION_LIST = /(?<=\bworks\ssuch\sas\s)[^.\r\n]+(?=\.)/i
    MAGAZINE_LIST = /(?<=\bmagazines:\s)[^\r\n]+?(?=\s+and\s+others\b)/i
    QUOTED_PUBLICATION_TITLE = %r{
      (?<prefix>
        \b(?:(?:published|appeared|publication)[^.!?\r\n]{0,120}\bas(?:\s+parts?\s+of)?|titled|entitled)\s
      )
      (?<title>&ldquo;.*?&rdquo;)
    }ix
    QUOTED_CITED_TITLE = %r{
      &ldquo;.*?&rdquo;
      (?=
        \s+in\s+[A-Z]
        (?:&(?:\#x[\dA-Fa-f]+|\#\d+|[A-Za-z]+);|[^.;\r\n])+?
        ,\s*\d{4}\b
      )
    }ix
    QUOTED_LANGUAGE_EXAMPLE = %r{
      (?<prefix>
        \b(?:(?:use|uses|using|word|phrase|sentence|expression|term)\s+|(?:say|says|said)\s*:\s*)
      )
      (?<example>&ldquo;.*?&rdquo;)
    }ix
    UNQUOTED_PUBLICATION_TITLE = %r{
      (?<=\bincluded\sin\s)
      [A-Z][A-Za-z'’-]*(?:\s+(?:[a-z]{1,4}|[A-Z][A-Za-z'’-]*)){2,}
      (?=\s+in\s+which\b)
    }x
    QUOTED_TITLE = /&ldquo;.*?&rdquo;/i
    TITLE_CONNECTORS = %w[a an and for from in of on or the to with].freeze
    MARKUP           = /#{FOOTNOTE}|#{MARKED_INLINE}|<!--.*?-->|<[^>]+>/m
    STANDALONE_MARKUP = /\A(?:<!--.*?-->|<[^>]+>)\z/m
    INDIC_SCRIPT     = /[\p{Devanagari}\p{Bengali}]+/
    TECHNICAL_VALUE  = /(?:\bEE\d+(?:\.\d+)?\b|\b[^\s<>]+\.html\b)/i
    PLACEHOLDER      = /__P\d{4}__/
    ADJACENT_PROTECTED_TERMS = /(?<left>__P\d{4}__)(?<spacing>\s+)(?<right>__P\d{4}__)/
    QUANTIFIER       = /(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)/i
    COORDINATED_PLACEHOLDER = %r{
      (?<first>\b#{QUANTIFIER}\s+[A-Za-z-]+)\s+and\s+
      (?<second>#{QUANTIFIER}\s+[A-Za-z-]+)\s+(?<term>#{PLACEHOLDER})
    }ix
    PROTECTED_MARKER = /⟦P[0-9a-f]+⟧/
    UNIT_MARKER      = /⟦U([0-9a-f]{64})⟧/
    DOCUMENT_MARKER  = /#{PROTECTED_MARKER}|#{UNIT_MARKER}/
    ESCAPED_ENTITY   = /&amp;(?=(?:#\d+|#x[\da-f]+|[a-z][\w]+);)/i
    HTML_STRUCTURE   = /<!--.*?-->|<[^>]+>/m
  end
end
