require_relative '../audiobook'
require_relative 'analysis/corpus'
require_relative 'analysis/detectors'
require_relative 'analysis/breaks'
require_relative 'analysis/report'
require_relative 'analysis/summary'

module Audiobook
  # Measures how well a book assembles. Every rule in the parser and the paragraph detector was
  # set from a number this produced over a corpus of real books, because a change that reads well
  # on one page usually costs something on another, and only the corpus shows the trade.
  module Analysis
    NAME_WIDTH = 34

    # Metadata lookup and OCR both call out to a model. Neither says anything about assembly, and
    # both turn a corpus run from seconds into minutes. The replacement is permanent for the
    # process, so it belongs to the command rather than to the library.
    def self.offline!
      return if @offline

      @offline = true
      Language.define_singleton_method(:book_metadata) { |_input| Language::BOOK_DEFAULTS.dup }
      OcrText.define_singleton_method(:transcribe) { |*, **| '' }
    end

    def self.report(path, pages: nil, lang: nil) = Report.for(path, pages: pages, lang: lang)

    # One run over the corpus: the per-book reports on disk and the table to diff against the next.
    def self.run(paths = nil, pages: nil, out: nil, &progress)
      Corpus.books(paths).map do |path|
        progress&.call(path)
        report = Report.for(path, pages: pages)
        report.write(out) if out
        [report.short_name, report.counts]
      rescue StandardError => e
        [Corpus.short_name(path), { error: "#{e.class}: #{e.message[0, 80]}" }]
      end
    end
  end
end
