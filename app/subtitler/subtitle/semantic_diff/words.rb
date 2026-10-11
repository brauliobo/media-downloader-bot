class Subtitler
  class Subtitle
    class SemanticDiff
      # Differences between the words of two matched cues.
      module Words
        private

        def compare_words(before_entry, after_entry, before_index, after_index)
          before_words = before_entry.words
          after_words  = after_entry.words
          return {events: [], max_start_delta: nil, max_finish_delta: nil} if before_words.empty? && after_words.empty?

          before_texts = before_words.map { |word| normalize_text(word.text) }
          after_texts  = after_words.map { |word| normalize_text(word.text) }
          alignment    = align_words(before_words, after_words, before_texts, after_texts)
          changes      = matched_word_changes(alignment[:pairs], before_words, after_words, before_texts, after_texts)
          cue          = { before_index: before_index, after_index: after_index }
          events       = []

          unless alignment[:unmatched_before].empty? && alignment[:unmatched_after].empty?
            events << {
              type:                   'word_count_changed',
              **cue,
              before_word_count:      before_words.length,
              after_word_count:       after_words.length,
              unmatched_before_count: alignment[:unmatched_before].length,
              unmatched_after_count:  alignment[:unmatched_after].length,
            }
          end
          events << { type: 'word_text_changed', **cue, changes: changes[:text] } unless changes[:text].empty?
          events << { type: 'word_timing_changed', **cue, changes: changes[:timing] } unless changes[:timing].empty?

          {
            events:          events,
            max_start_delta:  changes[:max_start],
            max_finish_delta: changes[:max_finish],
          }
        end

        # How the words that were matched up differ in text and in timing, and by how much at most.
        def matched_word_changes(pairs, before_words, after_words, before_texts, after_texts)
          changes = { text: [], timing: [], max_start: nil, max_finish: nil }

          pairs.each do |before_word_index, after_word_index|
            before_word = before_words.fetch(before_word_index)
            after_word  = after_words.fetch(after_word_index)
            before_text = before_texts.fetch(before_word_index)
            after_text  = after_texts.fetch(after_word_index)
            if before_text != after_text
              changes[:text] << {
                before_index: before_word_index,
                after_index:  after_word_index,
                before_text:  before_text,
                after_text:   after_text,
              }
            end

            start_delta  = after_word.start - before_word.start
            finish_delta = after_word.finish - before_word.finish
            changes[:max_start]  = [changes[:max_start] || 0.0, start_delta.abs].max
            changes[:max_finish] = [changes[:max_finish] || 0.0, finish_delta.abs].max
            next unless outside_tolerance?(start_delta) || outside_tolerance?(finish_delta)

            changes[:timing] << {
              before_index:  before_word_index,
              after_index:   after_word_index,
              before_text:   before_text,
              after_text:    after_text,
              start_delta:   rounded(start_delta),
              finish_delta:  rounded(finish_delta),
            }
          end
          changes
        end
      end
    end
  end
end
