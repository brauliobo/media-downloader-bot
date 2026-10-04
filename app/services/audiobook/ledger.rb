module Audiobook
  # What assembly left out, and which rule left it out. A stage that drops a line records it
  # here, so what a book loses can be read off the run instead of being inferred afterwards from
  # what the narration happens not to say. Nothing outside analysis asks for one, and with none
  # open the recording costs a nil check.
  class Ledger
    Drop = Struct.new(:rule, :page, :text)

    def self.current = Thread.current[:audiobook_ledger]

    def self.record(rule, lines) = current&.add(rule, lines)

    def self.collect
      previous = current
      Thread.current[:audiobook_ledger] = ledger = new
      yield
      ledger
    ensure
      Thread.current[:audiobook_ledger] = previous
    end

    attr_reader :drops

    def initialize = @drops = []

    def add(rule, lines)
      lines.each do |line|
        row = SymMash.wrap(line)
        @drops << Drop.new(rule, row.page, row.text.to_s.strip)
      end
    end

    def by_rule = @drops.group_by(&:rule).transform_values(&:size)

    # A page nothing was narrated from, where the book set enough lines on it to narrate.
    def dead_pages(spoken_pages, lines)
      pages = lines.map { |line| SymMash.wrap(line).page }.tally
      pages.count { |page, count| count >= MIN_LINES && !spoken_pages.include?(page) }
    end

    MIN_LINES = 10
  end
end
