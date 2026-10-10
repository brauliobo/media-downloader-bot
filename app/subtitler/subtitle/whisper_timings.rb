class Subtitler
  class Subtitle
    # Whisper sometimes collapses the words of a sentence into one instant. Where the document says
    # how fast people speak, such sentences are spread back over the time they must have taken.
    module WhisperTimings
      COLLAPSED_TICK = 0.011
      EXTREME_RATE   = 2.0
      MIN_RATE_PARTS = 2

      module_function

      def normalize!(sentences, duration:)
        reliable      = sentences.reject { |sentence| collapsed?(sentence) }
        document_rate = speech_rate(reliable)
        return unless document_rate

        speaker_rates = reliable.group_by(&:speaker_id).filter_map do |speaker_id, parts|
          next if speaker_id.nil? || parts.size < MIN_RATE_PARTS

          rate = speech_rate(parts)
          [speaker_id, rate] if rate
        end.to_h
        rates      = sentences.map { |sentence| speaker_rates.fetch(sentence.speaker_id, document_rate) }
        candidates = sentences.zip(rates).map do |sentence, rate|
          pathological?(sentence, rate)
        end
        return unless candidates.any?

        repair_pathological_runs!(sentences, candidates, rates, duration)
      end

      def speech_rate(sentences)
        words    = sentences.sum { |sentence| spoken_word_count(sentence) }
        duration = sentences.sum { |sentence| sentence.finish - sentence.start }
        return unless words.positive? && duration.positive?

        words.to_f / duration
      end

      def pathological?(sentence, average)
        count    = spoken_word_count(sentence)
        duration = sentence.finish - sentence.start
        return false unless count.positive? && duration.positive?

        collapsed?(sentence) && count / duration > average * EXTREME_RATE
      end

      def collapsed?(sentence)
        words = spoken_words(sentence)
        return false if words.empty?

        collapsed = words.count { |word| word.finish - word.start <= COLLAPSED_TICK }
        collapsed * 2 >= words.size
      end

      def spoken_word_count(sentence)
        spoken_words(sentence).size
      end

      def spoken_words(sentence)
        sentence.words.select { |word| word.text.match?(/[\p{L}\d]/) }
      end

      def repair_pathological_runs!(sentences, candidates, rates, duration)
        index = 0
        while index < sentences.size
          unless candidates.fetch(index)
            index += 1
            next
          end

          run_start  = index
          speaker_id = sentences.fetch(index).speaker_id
          index += 1 while index < sentences.size && candidates.fetch(index) &&
            sentences.fetch(index).speaker_id == speaker_id
          repair_pathological_run!(sentences, run_start...index, rates.fetch(run_start), duration)
        end
      end

      def repair_pathological_run!(sentences, range, average, duration)
        left       = range.begin.zero? ? 0.0 : sentences.fetch(range.begin - 1).finish
        right      = range.end == sentences.size ? document_finish(sentences, duration) : sentences.fetch(range.end).start
        available  = right - left
        run         = sentences[range]
        word_counts = run.map { |sentence| spoken_word_count(sentence) }
        desired     = word_counts.sum / average
        return unless available.positive? && desired.positive?

        duration    = [desired, available].min
        midpoint    = (run.first.start + run.last.finish) / 2.0
        start_time  = [[midpoint - duration / 2.0, left].max, right - duration].min
        finish_time = start_time + duration
        cursor       = start_time
        total_words  = word_counts.sum.to_f

        run.zip(word_counts).each_with_index do |(sentence, word_count), run_index|
          finish = run_index == run.size - 1 ? finish_time : cursor + duration * word_count / total_words
          redistribute_sentence_timing!(sentence, cursor, finish)
          cursor = finish
        end
      end

      def document_finish(sentences, duration)
        [duration.to_f, sentences.last.finish].max
      end

      def redistribute_sentence_timing!(sentence, start_time, finish_time)
        words   = sentence.words
        weights = words.map { |word| [word.text.strip.length, 1].max }
        total   = weights.sum.to_f
        cursor  = start_time

        words.zip(weights).each_with_index do |(word, weight), index|
          finish = index == words.size - 1 ? finish_time : cursor + (finish_time - start_time) * weight / total
          word.replace_timing!(start: cursor, finish: finish)
          sentence.source_words.fetch(index).replace_timing!(start: cursor, finish: finish)
          cursor = finish
        end
        sentence.replace_timing!(start: start_time, finish: finish_time)
      end
    end
  end
end
