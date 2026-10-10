require 'cgi'

class Subtitler
  class Subtitle
    class SemanticDiff
      DIFFERENCE_TYPES = %w[
        cue_removed cue_added text_changed timing_changed word_count_changed
        word_text_changed word_timing_changed speaker_changed cue_identifier_changed
        cue_settings_changed cue_presentation_changed
      ].freeze
      TIME_EPSILON = 1e-9

      def self.compare(before, after, time_tolerance: 0.01, max_details: 20)
        new(before, after, time_tolerance: time_tolerance, max_details: max_details).compare
      end

      def initialize(before, after, time_tolerance:, max_details:)
        @before         = before
        @after          = after
        @time_tolerance = time_tolerance.to_f
        @max_details    = max_details
      end

      def compare
        alignment = align_cues(before_entries, after_entries, before_texts, after_texts)
        maxima    = { cue_start: nil, cue_finish: nil, word_start: nil, word_finish: nil }
        events    = removed_events(alignment[:unmatched_before]) + added_events(alignment[:unmatched_after])
        alignment[:pairs].each do |before_index, after_index|
          events.concat(pair_events(before_index, after_index, maxima))
        end

        report(events, alignment, maxima)
      end

      private

      def before_entries = @before.entries
      def after_entries  = @after.entries
      def before_texts   = @before_texts ||= before_entries.map { |entry| normalize_text(entry.text) }
      def after_texts    = @after_texts ||= after_entries.map { |entry| normalize_text(entry.text) }

      def removed_events(indexes)
        indexes.map do |index|
          entry = before_entries.fetch(index)
          {
            type:          'cue_removed',
            before_index:  index,
            before_start:  rounded(entry.start),
            before_finish: rounded(entry.finish),
            before_text:   before_texts.fetch(index),
          }
        end
      end

      def added_events(indexes)
        indexes.map do |index|
          entry = after_entries.fetch(index)
          {
            type:         'cue_added',
            after_index:  index,
            after_start:  rounded(entry.start),
            after_finish: rounded(entry.finish),
            after_text:   after_texts.fetch(index),
          }
        end
      end

      # What differs between a cue and the cue it was matched with, raising the maxima as it goes.
      def pair_events(before_index, after_index, maxima)
        before_entry = before_entries.fetch(before_index)
        after_entry  = after_entries.fetch(after_index)
        before_text  = before_texts.fetch(before_index)
        after_text   = after_texts.fetch(after_index)
        events       = []

        events << {
          type:         'text_changed',
          before_index: before_index,
          after_index:  after_index,
          before_text:  before_text,
          after_text:   after_text,
        } if before_text != after_text

        events.concat(timing_events(before_entry, after_entry, before_index, after_index, maxima))
        if before_entry.speaker_id != after_entry.speaker_id
          events << {
            type:               'speaker_changed',
            before_index:       before_index,
            after_index:        after_index,
            before_speaker_id:  before_entry.speaker_id,
            after_speaker_id:   after_entry.speaker_id,
          }
        end

        compare_vtt_metadata(events, before_entry, after_entry, before_index, after_index)

        word_result = compare_words(before_entry, after_entry, before_index, after_index)
        events.concat(word_result[:events])
        update_maximum!(maxima, :word_start, word_result[:max_start_delta])
        update_maximum!(maxima, :word_finish, word_result[:max_finish_delta])
        events
      end

      def timing_events(before_entry, after_entry, before_index, after_index, maxima)
        start_delta  = after_entry.start - before_entry.start
        finish_delta = after_entry.finish - before_entry.finish
        update_maximum!(maxima, :cue_start, start_delta.abs)
        update_maximum!(maxima, :cue_finish, finish_delta.abs)
        return [] unless outside_tolerance?(start_delta) || outside_tolerance?(finish_delta)

        [{
          type:          'timing_changed',
          before_index:  before_index,
          after_index:   after_index,
          before_start:  rounded(before_entry.start),
          after_start:   rounded(after_entry.start),
          start_delta:   rounded(start_delta),
          before_finish: rounded(before_entry.finish),
          after_finish:  rounded(after_entry.finish),
          finish_delta:  rounded(finish_delta),
        }]
      end

      def report(events, alignment, maxima)
        details = events.sort_by { |event| detail_sort_key(event) }
        returned_details = details.first(@max_details)
        difference_counts = events.each_with_object(Hash.new(0)) do |event, counts|
          counts[event.fetch(:type)] += 1
        end
        summary = {
          identical:                  events.empty?,
          before_cue_count:            before_entries.length,
          after_cue_count:             after_entries.length,
          matched_cue_count:           alignment[:pairs].length,
          unmatched_before_cue_count:  alignment[:unmatched_before].length,
          unmatched_after_cue_count:   alignment[:unmatched_after].length,
          difference_count:            events.length,
          differences_by_type:         difference_counts.sort.to_h,
          max_start_delta:             rounded(maxima[:cue_start]),
          max_finish_delta:            rounded(maxima[:cue_finish]),
          max_word_start_delta:        rounded(maxima[:word_start]),
          max_word_finish_delta:       rounded(maxima[:word_finish]),
          max_timing_delta:             rounded(maxima.values.compact.max),
        }

        {
          summary:           summary,
          details:           returned_details,
          details_truncated: returned_details.length < details.length,
        }
      end


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

      def compare_vtt_metadata(events, before_entry, after_entry, before_index, after_index)
        before_is_vtt = @before.metadata['source_format'].to_s == 'vtt'
        after_is_vtt  = @after.metadata['source_format'].to_s == 'vtt'
        return unless before_is_vtt || after_is_vtt

        before_identifier = before_is_vtt ? vtt_identifier(before_entry) : nil
        after_identifier  = after_is_vtt ? vtt_identifier(after_entry) : nil
        if before_identifier != after_identifier && (before_identifier || after_identifier)
          events << {
            type:             'cue_identifier_changed',
            before_index:     before_index,
            after_index:      after_index,
            before_identifier: before_identifier,
            after_identifier:  after_identifier,
          }
        end

        before_settings = before_is_vtt ? vtt_settings(before_entry) : nil
        after_settings  = after_is_vtt ? vtt_settings(after_entry) : nil
        if before_settings != after_settings && (before_settings || after_settings)
          events << {
            type:            'cue_settings_changed',
            before_index:    before_index,
            after_index:     after_index,
            before_settings: before_settings,
            after_settings:  after_settings,
          }
        end

        before_presentation = before_is_vtt ? vtt_presentation(before_entry) : nil
        after_presentation  = after_is_vtt ? vtt_presentation(after_entry) : nil
        if before_presentation != after_presentation &&
            (before_presentation || after_presentation)
          events << {
            type:                 'cue_presentation_changed',
            before_index:         before_index,
            after_index:            after_index,
            before_presentation:  before_presentation,
            after_presentation:   after_presentation,
          }
        end
      end

      def vtt_identifier(entry)
        if entry.metadata.key?('prefix_lines')
          identifier = Array(entry.metadata['prefix_lines']).reverse.find do |line|
            !line.to_s.strip.empty?
          end
          return normalize_identifier(identifier)
        end
        return if entry.metadata.key?('block_index')

        normalize_identifier(entry.cue_id)
      end

      def normalize_identifier(identifier)
        return if identifier.nil?

        value = identifier.to_s.strip
        value.empty? ? nil : value
      end

      def vtt_settings(entry)
        timing_line = entry.metadata['timing_line']
        return unless timing_line

        match = timing_line.match(
          /\A\s*#{Subtitler::Timestamps::TIMESTAMP_VALUE}\s+-->\s+#{Subtitler::Timestamps::TIMESTAMP_VALUE}(.*)\z/
        )
        return unless match

        value = match[1].to_s.strip.split.join(' ')
        value.empty? ? nil : value
      end

      def vtt_presentation(entry)
        return unless entry.metadata.key?('content_lines')

        Array(entry.metadata['content_lines']).map do |line|
          value = line.to_s.gsub(Subtitler::Timestamps::INLINE_TIMESTAMP, '')
          CGI.unescapeHTML(value).strip.split.join(' ')
        end
      end

      def compare_words(before_entry, after_entry, before_index, after_index)
        before_words = before_entry.words
        after_words  = after_entry.words
        return {events: [], max_start_delta: nil, max_finish_delta: nil} if before_words.empty? && after_words.empty?

        before_texts = before_words.map { |word| normalize_word_text(word.text) }
        after_texts  = after_words.map { |word| normalize_word_text(word.text) }
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

      def normalize_text(text)
        plain = text.to_s.gsub(/<br\s*\/?\s*>/i, ' ').gsub(/<[^>]*>/, '')
        Nokogiri::HTML5.fragment(plain).text.split.join(' ')
      end

      def normalize_word_text(text)
        normalize_text(text)
      end

      def outside_tolerance?(delta)
        delta.abs > @time_tolerance + TIME_EPSILON
      end

      def update_maximum!(maxima, key, value)
        return if value.nil?

        maxima[key] = [maxima[key] || 0.0, value].max
      end

      def rounded(value)
        return if value.nil?

        result = value.to_f.round(6)
        result.zero? ? 0.0 : result
      end

      def detail_sort_key(event)
        before_index = event[:before_index]
        after_index  = event[:after_index]
        cue_index    = [before_index, after_index].compact.min || Float::INFINITY
        [cue_index, DIFFERENCE_TYPES.index(event.fetch(:type)), before_index || Float::INFINITY,
         after_index || Float::INFINITY]
      end
    end
  end
end
