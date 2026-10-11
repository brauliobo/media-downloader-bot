class Subtitler
  class Subtitle
    # Entries cut into sentences, and the ones too long for a cue cut where the text balances best.
    module Splitting
      def sentence_entries
        sentences = @entries.chunk_while do |left, right|
          representation_and_boundary(left) == representation_and_boundary(right)
        end.flat_map do |run|
          if run.first.words.any?
            Sentences.from_entries(run.map(&:deep_copy)).each do |entry|
              entry.assign_speaker!(run.first.speaker_id)
              entry.assign_cue!(run.first.cue_id)
              entry.replace_metadata!(derived_metadata(run.first.metadata))
            end
          else
            run.flat_map { |entry| text_sentence_entries(entry) }
          end
        end.select { |entry| entry.finish > entry.start }

        WhisperTimings.normalize!(sentences, duration: @metadata['duration']) if @metadata['timing_source'] == 'whisper'
        sentences
      end

      def split_long_entries!(max_chars: MAX_ENTRY_CHARS)
        replace_entries!(@entries.flat_map { |entry| split_entry(entry, max_chars) })
        rebuild_text_from_entries!
      end

      private

      def representation_and_boundary(entry)
        [entry.words.any?, entry.cue_id, entry.speaker_id]
      end

      def text_sentence_entries(entry)
        parts = Text::SentenceSplitter.sentences(entry.text.strip)
        return [] if parts.empty?
        return [derived_entry_copy(entry)] if parts.size == 1

        build_text_entries(entry, parts, partition_source: true)
      end

      def split_entry(entry, max_chars)
        return [entry] if entry.text.strip.length <= max_chars

        words = entry.words.reject { |word| word.text.strip.empty? }
        if words.empty?
          parts = split_items(entry.text.strip.split(/\s+/), max_chars) { |token| token }
          return [entry] if parts.size <= 1

          build_text_entries(entry, parts.map { |part| part.join(' ') })
        else
          split_items(words, max_chars) { |word| word.text.strip }.map do |chunk|
            build_word_entry(entry, chunk)
          end
        end
      end

      def build_word_entry(source, words)
        copies = words.map(&:deep_copy)
        Entry.new(
          start:        copies.first.start,
          finish:       copies.last.finish,
          text:         copies.map { |word| word.text.strip }.join(' '),
          words:        copies,
          speaker_id:   source.speaker_id,
          cue_id:       source.cue_id,
          source_text:  source.source_text,
          source_words: source.source_words.map(&:deep_copy),
          metadata:     derived_metadata(source.metadata)
        )
      end

      def build_text_entries(source, texts, partition_source: false)
        total    = texts.sum(&:length)
        duration = [source.finish - source.start, 0].max
        cursor   = source.start

        texts.map.with_index do |text, index|
          span   = total.zero? ? 0 : duration * text.length.to_f / total
          finish = index == texts.length - 1 ? source.finish : cursor + span
          entry  = Entry.new(
            start:        cursor,
            finish:       finish,
            text:         text,
            words:        [],
            speaker_id:   source.speaker_id,
            cue_id:       source.cue_id,
            source_text:  partition_source ? text : source.source_text,
            source_words: source.source_words.map(&:deep_copy),
            metadata:     derived_metadata(source.metadata)
          )
          cursor = finish
          entry
        end
      end

      def split_items(items, max_chars, &item_text)
        min_next_size = (max_chars * 0.35).to_i
        buckets       = []
        buffer        = []

        items.each_with_index do |item, index|
          sample = join_items(buffer + [item], item_text)
          if sample.length > max_chars && buffer.any?
            next_text = join_items(items[index..] || [], item_text)
            if next_text.length < min_next_size && buffer.size > 1
              split_index = find_balanced_split(buffer, max_chars, min_next_size, next_text.length, &item_text)
              if split_index && split_index < buffer.size - 1
                buckets << buffer[0..split_index]
                buffer = buffer[(split_index + 1)..] + [item]
              else
                buckets << buffer
                buffer = [item]
              end
            else
              buckets << buffer
              buffer = [item]
            end
          else
            buffer << item
          end
        end
        buckets << buffer if buffer.any?
        buckets
      end

      def find_balanced_split(buffer, max_chars, min_next_size, next_remaining, &item_text)
        return if buffer.size <= 1

        best_index = nil
        best_score = Float::INFINITY
        (0..buffer.size - 2).each do |index|
          first_text = join_items(buffer[0..index], item_text)
          next_text  = join_items(buffer[(index + 1)..], item_text)
          next_total = next_text.length + next_remaining
          next if first_text.length > max_chars || next_total < min_next_size

          score = (max_chars - first_text.length).abs + (min_next_size - next_total).abs
          if score < best_score
            best_score = score
            best_index = index
          end
        end
        best_index
      end

      def join_items(items, item_text)
        items.map { |item| item_text.call(item) }.join(' ').strip
      end
    end
  end
end
