module Ewprs
  module TranslationMarkup
    include Patterns

    def html_structure_compatible?(source, translated, allow_moved_inline_nesting: false)
      source_structure = html_structure(source)
      translated_structure = html_structure(translated)
      return true if translated_structure == source_structure

      inline = ->(tag) { tag.match?(/\A<\/?(?:i|em)\b[^>]*>\z/i) }
      return false unless source_structure.reject(&inline) == translated_structure.reject(&inline)
      source_inline = source_structure.select(&inline)
      translated_inline = translated_structure.select(&inline)
      return false unless source_inline.tally == translated_inline.tally

      return source_inline == translated_inline if source_inline.length <= 2
      return true unless inline_tags_balanced?(source_inline)

      return false unless inline_tags_balanced?(translated_inline)
      return true if allow_moved_inline_nesting

      inline_tag_shape(source_inline) == inline_tag_shape(translated_inline)
    end

    def html_structure(html)
      html.to_s.scan(HTML_STRUCTURE).map { |tag| blank_navigation_attributes(tag) }
    end

    def blank_navigation_attributes(tag)
      tag.gsub(NAVIGATION_ATTRIBUTE) do
        name, equals, quote, = Regexp.last_match.captures
        "#{name}#{equals}#{quote}#{quote}"
      end
    end

    def inline_tags_balanced?(tags)
      stack = []
      tags.each do |tag|
        match = tag.match(/\A<(\/)?(i|em)\b[^>]*>\z/i)
        next unless match

        if match[1]
          return false unless stack.pop&.casecmp?(match[2])
        else
          stack << match[2]
        end
      end
      stack.empty?
    end

    def inline_tag_shape(tags)
      tags.map { |tag| tag.match?(%r{\A</}) ? :close : :open }
    end
    private :html_structure_compatible?, :html_structure, :blank_navigation_attributes, :inline_tags_balanced?,
            :inline_tag_shape
  end
end
