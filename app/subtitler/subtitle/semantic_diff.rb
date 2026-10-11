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

      include Alignment
      include VttMetadata
      include Words

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

      def normalize_text(text)
        plain = text.to_s.gsub(/<br\s*\/?\s*>/i, ' ').gsub(/<[^>]*>/, '')
        Nokogiri::HTML5.fragment(plain).text.split.join(' ')
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
