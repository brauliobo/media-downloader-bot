class Subtitler
  # Subtitle entries carry words; speech is read by sentence, so their words are regrouped at sentence ends.
  module Sentences
    EOS_PUNCT          = /[.!?…]$/
    CLOSERS_ONLY       = /\A["')\]]+\z/
    TITLE_ABBREVIATION = /\A(?:Mr|Mrs|Ms|Dr|Prof|Sr|Sra|St)\.\z/i

    module_function

    def from_entries(entries)
      unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Subtitle::Entry) }
        raise TypeError, 'entries must contain only Subtitler::Subtitle::Entry objects'
      end

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
      end
      flush!(sentences, cur_words)
      sentences
    end

    def each_word(entries, &block)
      entries.each { |entry| entry.words.each { |word| block.call(word.deep_copy) } }
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

    def eos_punct?(raw) = raw.strip.match?(EOS_PUNCT)
    def title_abbreviation?(raw) = raw.strip.match?(TITLE_ABBREVIATION)
    def closer_only?(raw) = raw.match?(CLOSERS_ONLY)
  end
end
