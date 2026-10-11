class Subtitler
  class Subtitle
    class SemanticDiff
      # Pairs up cues, and words within a cue, by how well their text and timing agree.
      module Alignment
        private

        def align_cues(before_entries, after_entries, before_texts, after_texts)
          if before_entries.empty? || after_entries.empty?
            return {
              pairs:            [],
              unmatched_before: (0...before_entries.length).to_a,
              unmatched_after:  (0...after_entries.length).to_a,
            }
          end

          candidates = cue_candidates(before_entries, after_entries, before_texts, after_texts)
          ranked     = candidates.sort_by { |candidate| candidate.fetch(:score) }
                                 .map { |candidate| [candidate.fetch(:before_index), candidate.fetch(:after_index)] }
          greedy_alignment(ranked, before_entries.length, after_entries.length)
        end

        # Every cue that overlaps or sits near another, scored so that the better match sorts first.
        def cue_candidates(before_entries, after_entries, before_texts, after_texts)
          after_order  = (0...after_entries.length).sort_by do |index|
            [after_entries.fetch(index).start, after_entries.fetch(index).finish, index]
          end
          after_starts = after_order.map { |index| after_entries.fetch(index).start }
          candidates   = []
          seen         = {}

          before_entries.each_with_index do |before_entry, before_index|
            candidate_after_indices(before_entry, after_order, after_starts, after_entries).each do |after_index|
              key = [before_index, after_index]
              next if seen[key]

              seen[key] = true
              after_entry = after_entries.fetch(after_index)
              overlap     = overlap_duration(before_entry, after_entry)
              union       = [before_entry.finish, after_entry.finish].max -
                            [before_entry.start, after_entry.start].min
              overlap_ratio = union.positive? ? overlap / union : 0.0
              exact_text   = before_texts.fetch(before_index) == after_texts.fetch(after_index)
              candidates << {
                before_index: before_index,
                after_index:  after_index,
                score:        [
                  exact_text ? 0 : 1,
                  overlap.positive? ? 0 : 1,
                  -overlap_ratio,
                  temporal_gap(before_entry, after_entry),
                  (before_entry.finish - before_entry.start -
                    (after_entry.finish - after_entry.start)).abs,
                  before_index,
                  after_index,
                ],
              }
            end
          end
          candidates
        end

        # Takes the candidate pairs best first, each cue or word being used once. Where both sides have
        # the same count, what is left over is paired in order: a word that was only reworded.
        def greedy_alignment(ranked_pairs, before_count, after_count, pair_up_rest: false)
          used_before = {}
          used_after  = {}
          pairs       = []
          take = lambda do |before_index, after_index|
            used_before[before_index] = used_after[after_index] = true
            pairs << [before_index, after_index]
          end

          ranked_pairs.each { |before_index, after_index| take.call(before_index, after_index) unless used_before[before_index] || used_after[after_index] }
          if pair_up_rest && before_count == after_count
            free_before = (0...before_count).reject { |index| used_before[index] }
            free_after  = (0...after_count).reject { |index| used_after[index] }
            free_before.zip(free_after).each { |before_index, after_index| take.call(before_index, after_index) }
          end

          {
            pairs:            pairs.sort,
            unmatched_before: (0...before_count).reject { |index| used_before[index] },
            unmatched_after:  (0...after_count).reject { |index| used_after[index] },
          }
        end

        def candidate_after_indices(before_entry, after_order, after_starts, after_entries)
          first = lower_bound(after_starts, before_entry.start)
          indices = []
          index   = first - 1
          while index >= 0 && after_entries.fetch(after_order.fetch(index)).finish > before_entry.start
            indices << after_order.fetch(index)
            index -= 1
          end

          index = first
          while index < after_order.length && after_entries.fetch(after_order.fetch(index)).start < before_entry.finish
            indices << after_order.fetch(index)
            index += 1
          end

          indices << after_order.fetch(first - 1) if first.positive? && indices.empty?
          indices << after_order.fetch(first) if first < after_order.length && indices.empty?
          indices.uniq
        end

        def lower_bound(values, target)
          low  = 0
          high = values.length
          while low < high
            middle = (low + high) / 2
            if values.fetch(middle) < target
              low = middle + 1
            else
              high = middle
            end
          end
          low
        end

        def overlap_duration(left, right)
          [
            [left.finish, right.finish].min - [left.start, right.start].max,
            0.0,
          ].max
        end

        def temporal_gap(left, right)
          return 0.0 if overlap_duration(left, right).positive?

          [
            (left.start - right.finish).abs,
            (right.start - left.finish).abs,
          ].min
        end

        def align_words(before_words, after_words, before_texts, after_texts)
          candidates = []
          before_texts.each_with_index do |before_text, before_index|
            after_texts.each_with_index do |after_text, after_index|
              next unless before_text == after_text

              before_word = before_words.fetch(before_index)
              after_word  = after_words.fetch(after_index)
              candidates << [
                (before_word.start - after_word.start).abs +
                  (before_word.finish - after_word.finish).abs,
                (before_index - after_index).abs,
                before_index,
                after_index,
              ]
            end
          end

          ranked = candidates.sort.map { |_distance, _position, before_index, after_index| [before_index, after_index] }
          greedy_alignment(ranked, before_words.length, after_words.length, pair_up_rest: true)
        end
      end
    end
  end
end
