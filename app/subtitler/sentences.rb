class Subtitler
  # Subtitle entries carry words; speech is read by sentence, so their words are regrouped at sentence ends.
  module Sentences
    CLOSERS_ONLY       = /\A["')\]]+\z/
    TITLE_ABBREVIATION = /\A(?:Mr|Mrs|Ms|Dr|Prof|Sr|Sra|St)\.\z/i
    # Speech transcribed without punctuation (a separated voice) would be one sentence for the whole media: past these it is cut at its longest pause.
    MAX_WORDS          = 60
    MAX_DURATION       = 15.0
    MIN_WORDS          = 20

    module_function

    def from_entries(entries)
      sentences, cur_words, eos_pending = [], [], false
      each_word(entries) do |word|
        raw = word.text
        next if raw.strip.empty?
        if eos_pending
          if closer_only?(raw)
            attach_closer!(cur_words, word)
            flush!(sentences, cur_words)
            eos_pending = false
            next
          else
            flush!(sentences, cur_words)
            eos_pending = false
          end
        end
        cur_words << word
        eos_pending = true if eos_punct?(raw) && !title_abbreviation?(raw)
        split_at_longest_pause!(sentences, cur_words) if too_long?(cur_words)
      end
      flush!(sentences, cur_words)
      sentences
    end

    def each_word(entries, &block)
      entries.each { |entry| entry.words.each { |word| block.call(word.deep_copy) } }
    end

    def too_long?(words) = words.size > MAX_WORDS || (words.size > MIN_WORDS && words.last.finish - words.first.start > MAX_DURATION)

    def split_at_longest_pause!(sentences, cur_words)
      at   = (MIN_WORDS - 1...cur_words.size - 1).max_by { |idx| [cur_words[idx + 1].start - cur_words[idx].finish, idx] }
      rest = cur_words.slice!(at + 1..)
      flush!(sentences, cur_words)
      cur_words.concat(rest)
    end

    def attach_closer!(cur_words, word)
      cur_words.last.merge!(word)
    end

    def flush!(sentences, cur_words)
      return if cur_words.empty?

      sentences << Subtitle::Entry.new(
        text: cur_words.map { |word| word.text.strip }.join(' '),
        start: cur_words.first.start,
        finish: cur_words.last.finish,
        words: cur_words.dup
      )
      cur_words.clear
    end

    def eos_punct?(raw) = Text::Punctuation.stop?(raw.strip)
    def title_abbreviation?(raw) = raw.strip.match?(TITLE_ABBREVIATION)
    def closer_only?(raw) = raw.match?(CLOSERS_ONLY)
  end
end
