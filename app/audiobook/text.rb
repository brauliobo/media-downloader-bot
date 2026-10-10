module Audiobook
  # Text as the source printed it, made into text that can be compared and joined.
  module Text
    OVERLAP_MAX_WORDS = 8

    module_function

    def normalize(str)
      clean = str.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      clean = clean.gsub(/<[^>]+>/, '')
      clean = clean.gsub(/[­]/, '')
      clean = clean.gsub(/[​‌‍⁠﻿]/, '')
      clean = clean.gsub(/[\u0009\u000A\u000B\u000C\u000D    -     　]+/u, ' ')
      clean.strip
    end

    # Two lines say the same thing when they read the same; a folio differs only in its digits.
    def comparable(text) = text.to_s.downcase.gsub(/\s+/, ' ').strip
    def comparable_key(text) = comparable(text).gsub(/\d+/, '<d>')

    # Join an array of line strings from a PDF into one paragraph string using sane defaults
    def join_lines(lines)
      merged = Array(lines).map { |line| normalize(line.to_s.sub(/[­‐‑]\z/, '-')) }.reject(&:empty?).reduce(nil) do |text, line|
        next line unless text

        if text.end_with?('-')
          # A hyphen between digits is a range; before a lowercase continuation it splits a word; else a dash.
          next "#{text}#{line}" if text.match?(/\d-\z/) && line.match?(/\A\d/)

          line.match?(/\A\p{Ll}/u) ? "#{text.chomp('-').rstrip}#{line}" : "#{text} #{line}"
        else
          overlap = overlapping_word_count(text, line)
          words = line.split(/\s+/).drop(overlap)
          [text, words.join(' ')].reject(&:empty?).join(' ')
        end
      end

      normalize(merged)
    end

    def overlapping_word_count(left, right)
      left_words = overlap_words(left)
      right_words = overlap_words(right)
      max = [left_words.size, right_words.size, OVERLAP_MAX_WORDS].min

      max.downto(2) do |count|
        return count if left_words.last(count) == right_words.first(count)
      end

      return 1 if left_words.last && left_words.last == right_words.first && left_words.last.length >= 6

      0
    end

    def overlap_words(text)
      text.to_s.split(/\s+/)
        .map { |word| word.downcase.gsub(/\A[^\p{L}\p{N}]+|[^\p{L}\p{N}]+\z/u, '') }
        .reject(&:empty?)
    end
  end
end
