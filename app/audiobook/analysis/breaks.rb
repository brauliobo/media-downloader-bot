module Audiobook
  module Analysis
    # Why a block ended where it did. A paragraph is marked out by the page it is set on, so a
    # break the page cannot explain is one the listener hears in the wrong place.
    module Breaks
      GEOMETRY = %i[gap indent ragged].freeze
      # A page break on its own never ends a paragraph, so it does not explain one.
      INCIDENTAL = %i[page].freeze

      def self.tally(path, pages: nil, lang: nil)
        found = collect(path, pages: pages, lang: lang)
        SymMash.new(
          book:        Corpus.short_name(path),
          breaks:      found.size,
          geometry:    found.count { |reasons| (reasons & GEOMETRY).any? },
          markup:      found.count { |reasons| reasons.include?(:block) },
          unexplained: found.count { |reasons| unexplained?(reasons) }
        )
      end

      def self.unexplained?(reasons) = (reasons - INCIDENTAL).empty? || (reasons - INCIDENTAL) == [:sentence]

      def self.collect(path, pages: nil, lang: nil)
        found = []
        Paragraph::Detector.observe(->(previous, line, buf, grid) { found << reasons(previous, line, buf, grid) }) do
          Corpus.open(path, pages: pages, lang: lang)
        end
        found
      end

      # The same questions the detector asked itself, named as the report names them.
      def self.reasons(previous, line, buf, grid)
        finished = Sentence.ends_with_punctuation?(buf.map(&:text).join(' ').strip)

        structural(previous, line) + layout(previous, line, grid, finished) +
          [(:block if previous.new_block?(line)), (:page if line.page_number != previous.page_number),
           (:lang if line.language != previous.language)].compact
      end

      def self.structural(previous, line)
        [
          (:font   if line.font_changed?(previous)),
          (:style  if !line.font_changed?(previous) && line.style_changed?(previous)),
          (:role   if FontRoles.heading_item?(previous) != FontRoles.heading_item?(line)),
          (:enum   if TextHelpers.enumerated?(line.text)),
          (:label  if FontRoles.labeled_line?(line)),
          (:toc    if TextHelpers.toc_entry?(previous.text)),
          (:marker if TextHelpers.marker_line?(line.text)),
        ].compact
      end

      def self.layout(previous, line, grid, finished)
        [
          (:gap      if grid.gap?(previous, line)),
          (:indent   if grid.indented?(line) && grid.at_column?(previous)),
          (:ragged   if finished && grid.ragged_end?(previous)),
          (:sentence if finished && line.starts_with_capital? && grid.flat?(line)),
        ].compact
      end
    end
  end
end
