require_relative '../../audiobook'

module Audiobook
  module Analysis
    # The books a run measures, and the few things only their filenames can tell us. The corpus
    # is real books people sent to the bot, so it is kept out of the repository.
    module Corpus
      ROOT      = 'tmp/analysis/pdfs'.freeze
      FORMATS   = '*.{pdf,epub}'.freeze
      # Nothing in a file says what language it is in until it has been parsed, which is what we
      # are measuring; the corpus is small enough to name the exceptions to Portuguese.
      LANGUAGES = {
        /kybalion|path_of_empowerment|savin|32 reasons|fixing_my_gaze|why_good_people|what_doctors|beginners guide|fauci/i => 'en',
        /adi(?:o|ó)s|salud prohibida|cura_en_un_minuto|milagroso/i => 'es',
      }.freeze
      DEFAULT_LANGUAGE = 'pt'.freeze

      def self.books(paths = nil)
        paths.presence || Dir[File.join(ROOT, FORMATS)].sort
      end

      def self.name_for(path) = File.basename(path, File.extname(path))

      # A table column has to fit, and two books in the corpus differ only in their last few
      # characters, so a trimmed name keeps its tail as well as its head.
      def self.short_name(path)
        name = name_for(path)
        name.size <= NAME_WIDTH ? name : "#{name[0, NAME_WIDTH - 9]}…#{name[-8..]}"
      end

      def self.language_for(path)
        LANGUAGES.find { |pattern, _| File.basename(path).match?(pattern) }&.last || DEFAULT_LANGUAGE
      end

      def self.open(path, pages: nil, lang: nil)
        opts = SymMash.new(alang: lang || language_for(path), source_base: name_for(path), pages: pages_for(path, pages))
        Book.from_input(path, opts: opts, translate: false)
      end

      # A range wider than the book raises, so it is clamped to the pages the book has.
      def self.pages_for(path, pages)
        return if pages.blank?

        last = pages[/-(\d+)\z/, 1].to_i
        return pages unless last.positive?

        count = page_count(path)
        count && count < last ? "1-#{count}" : pages
      end

      def self.page_count(path)
        Parsers::Pdf.extract_page_count(path) if File.extname(path).casecmp('.pdf').zero?
      end
    end
  end
end
