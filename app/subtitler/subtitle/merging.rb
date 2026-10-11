class Subtitler
  class Subtitle
    # Entries joined into longer ones where the words and the gaps between them allow it.
    module Merging
      def merge_split_words!
        @entries.each(&:merge_split_words!)

        index = 1
        while index < @entries.length
          previous = @entries[index - 1]
          current  = @entries[index]

          while merge_cross_entry_word?(previous, current)
            suffix = current.words.first
            previous.words.last.merge!(suffix)
            current.replace_words!(current.words.drop(1))
            previous.replace_timing!(start: previous.start, finish: [previous.finish, suffix.finish].max)
            transfer_leading_source_word!(current, previous)
          end

          previous.rebuild_text_from_words! unless previous.words.empty?
          if current.words.empty?
            remaining = @entries.dup
            remaining.delete_at(index)
            replace_entries!(remaining)
          else
            current.replace_timing!(start: current.words.first.start, finish: [current.finish, current.words.last.finish].max)
            current.rebuild_text_from_words!
            index += 1
          end
        end

        rebuild_text_from_entries!
      end

      def merge_adjacent!(max_chars: MAX_ENTRY_CHARS, gap_threshold: 1.0, respect_speaker: true)
        return self if @entries.empty?

        merged  = []
        current = @entries.first
        @entries.drop(1).each do |entry|
          if mergeable?(current, entry, max_chars, gap_threshold, respect_speaker)
            current.merge!(entry)
          else
            merged << current
            current = entry
          end
        end
        replace_entries!(merged << current)
        rebuild_text_from_entries!
      end

      private

      def merge_cross_entry_word?(previous, current)
        return false if previous.words.empty? || current.words.empty?

        !current.words.first.text.start_with?(' ') && !previous.words.last.text.strip.match?(/[.!?]$/)
      end

      def transfer_leading_source_word!(source, target)
        moved = source.source_words.first
        return unless moved

        target_words = target.source_words + [moved.deep_copy]
        source_words = source.source_words.drop(1)
        target.replace_source!(text: source_text_from(target_words), words: target_words)
        source.replace_source!(text: source_text_from(source_words), words: source_words)
      end

      def source_text_from(words)
        words.map(&:text).join.strip
      end

      def mergeable?(left, right, max_chars, gap_threshold, respect_speaker)
        if respect_speaker && !left.speaker_id.nil? && !right.speaker_id.nil? && left.speaker_id != right.speaker_id
          return false
        end

        gap      = right.start - left.finish
        combined = left.text.length + 1 + right.text.length
        gap <= gap_threshold && combined <= max_chars
      end
    end
  end
end
