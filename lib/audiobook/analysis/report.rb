require 'benchmark'
require 'fileutils'
require_relative 'corpus'
require_relative 'coverage'
require_relative 'detectors'

module Audiobook
  module Analysis
    # One book measured: the counts that go in the summary and the samples to read when a count
    # moves. Writing the assembled YAML beside the report makes a change inspectable line by line.
    class Report
      SAMPLES       = 8
      SAMPLE_CHARS  = 160
      DUPLICATE_MIN = 3

      attr_reader :path, :book, :seconds, :hits

      def self.for(path, pages: nil, lang: nil)
        book = nil
        seconds = Benchmark.realtime { book = Corpus.open(path, pages: pages, lang: lang) }
        new(path, book, seconds)
      end

      def initialize(path, book, seconds = 0.0)
        @path    = path
        @book    = book
        @seconds = seconds
        @spoken  = Detectors.spoken(book)
        @hits    = Detectors.hits(book, @spoken)
        @hits[:unspoken] = Coverage.unspoken(book, @spoken)
      end

      def name = Corpus.name_for(path)
      def short_name = Corpus.short_name(path)

      def counts
        Detectors.names.to_h { |detector| [detector, @hits[detector].size] }.merge(
          sentences:  @spoken.size,
          unspoken:   @hits[:unspoken].size,
          paras:      count_items { |item| Detectors.narrated?(item) },
          refs:       references.size,
          empty_refs: references.count { |reference| reference.sentences.empty? },
          levels:     levels,
          secs:       seconds.round(1),
          dups:       duplicates.size
        )
      end

      def to_s
        [headline, *sections].join("\n")
      end

      def write(dir)
        FileUtils.mkdir_p(dir)
        book.write(File.join(dir, "#{name}.yml"))
        File.write(File.join(dir, "#{name}.issues.md"), to_s)
      end

      private

      def headline
        <<~HEAD
          # #{name} (#{book.pages.size} pages, #{@spoken.size} sentences, #{seconds.round(1)}s, lang=#{book.language})
          font_roles: body=#{book.font_roles&.body_size} map=#{book.font_roles&.map&.size} levels=#{levels}
          references: #{references.size} (#{references.count { |reference| reference.sentences.empty? }} unbound)
          repeated sentences (>=#{DUPLICATE_MIN}x): #{duplicates.size} #{duplicates.keys.first(5).inspect}
          headings: #{count_items { |item| item.is_a?(Heading) }} sections: #{count_items { |item| item.is_a?(Section) }}
        HEAD
      end

      def sections
        @hits.reject { |_, list| list.empty? }.sort_by { |_, list| -list.size }.map do |detector, list|
          share = @spoken.empty? ? 0 : (100.0 * list.size / @spoken.size).round(1)
          samples = list.first(SAMPLES).map { |page, text| "  p#{page}: #{text[0, SAMPLE_CHARS].inspect}" }
          ["## #{detector}: #{list.size} (#{share}%)", *samples, ''].join("\n")
        end
      end

      def references
        @references ||= book.pages.flat_map { |page| page.items.grep(Paragraph) }
          .flat_map(&:sentences).flat_map(&:references)
      end

      # The same line read three times over is a running head the furniture pass missed.
      def duplicates
        @duplicates ||= @spoken.map { |sentence, _| TextHelpers.comparable(sentence.text) }
          .tally.select { |text, count| count >= DUPLICATE_MIN && text.split.size >= 2 }
      end

      def levels = book.font_roles&.map&.values&.filter_map { |entry| entry[:level] }&.uniq&.size || 0

      def count_items(&keep) = book.pages.sum { |page| page.items.count(&keep) }
    end
  end
end
