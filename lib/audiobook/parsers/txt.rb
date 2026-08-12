require_relative 'base'

module Audiobook
  module Parsers
    class Txt < Base
      def self.extract_data(path, stl: nil, opts: nil, **_kwargs)
        paragraphs = paragraphs_from_plain_text(read_text(path))
        lines = paragraphs.filter_map do |paragraph|
          font = TextHelpers.heading_line?(paragraph) ? HEADING_FONT_SIZE : BODY_FONT_SIZE
          line(paragraph, font)
        end
        page_count = paginate(lines, words_per_page(opts))
        parser_opts = SymMash.new(opts || {})
        parser_opts.includeall = true

        SymMash.new(
          metadata: SymMash.new(page_count: page_count),
          content:  SymMash.new(lines: lines, images: []),
          opts:     parser_opts
        )
      end
    end
  end
end
