module Dubbing
  module VoiceReference
    # What a speaker's reference may be made of, best first. Each kind is a tier, tried while the one before it
    # yields nothing: sentences that sound clean, any sentence, then the diarized turns.
    class Candidates
      # Furthest a cut may move outward to find silence.
      EDGE_ROOM         = 0.25
      # Seconds of another speaker over a sentence that still count as that speaker alone.
      OVERLAP_TOLERANCE = 0.15
      # Sentences whose audio is measured, the most confidently transcribed first.
      SHORTLIST         = 8
      # Average word probability times its 10th percentile, as VoiceReference::Selector asks of a recording.
      MIN_CONFIDENCE    = 0.85 * 0.75

      def initialize(input_path, sentences:, segments:, analyzer:, cutter:, max_duration: MAX_DURATION)
        @input_path   = input_path
        @sentences    = sentences
        @segments     = segments
        @analyzer     = analyzer
        @cutter       = cutter
        @max_duration = max_duration
      end

      # Confident sentences with no one else talking, cut in clean silence and with a usable signal.
      def strict(speaker_id, dir:) = fill(ranked(speaker_id, dir, strict: true))

      # Any sentence, for a speaker whose sentences are none of those.
      def relaxed(speaker_id, dir:) = fill(ranked(speaker_id, dir, strict: false))

      # The speaker's diarized turns. They carry no text, so whoever uses them has to transcribe the audio.
      def turns(speaker_id, dir: nil)
        turns = @segments.select { |segment| segment.speaker_id == speaker_id && segment.finish > segment.start }
        fill(turns.map { |turn| Selection.new(start: turn.start.to_f, duration: [turn.finish - turn.start, @max_duration].min, text: '') })
      end

      private

      attr_reader :input_path, :analyzer, :cutter, :max_duration

      def ranked(speaker_id, dir, strict:)
        shortlist(speaker_id, strict)
          .filter_map { |selection| scored(selection, dir, strict) }
          .sort_by { |selection| -selection.score }
      end

      def shortlist(speaker_id, strict)
        selections = sentence_selections(speaker_id)
        selections = selections.select { |selection| confident?(selection) && alone?(speaker_id, selection) } if strict
        selections.sort_by { |selection| [-(selection.confidence || 1.0), selection.start] }.first(SHORTLIST)
      end

      def scored(selection, dir, strict)
        cut = cutter.call(input_path, selection, dir: dir)
        return if strict && !cut.clean

        measured = analyzer.public_send(strict ? :assess : :measure, candidate(cut))
        cut.with(score: measured.score) if measured
      end

      def candidate(selection)
        ::VoiceReference::Candidate.new(
          audio: input_path, start: selection.start, finish: selection.start + selection.duration,
          text: selection.text, confidence: selection.confidence || 1.0
        )
      end

      # Best first until the cap is reached, then back in the order they were spoken.
      def fill(ranked)
        total = 0.0
        ranked.each_with_object([]) do |selection, chosen|
          next if total + selection.duration > max_duration

          chosen << selection
          total += selection.duration
        end.sort_by(&:start)
      end

      def sentence_selections(speaker_id)
        @sentences.each_with_index.filter_map do |sentence, idx|
          next unless sentence.speaker_id == speaker_id

          selection(sentence, idx.positive? ? @sentences[idx - 1] : nil, @sentences[idx + 1])
        end
      end

      def selection(sentence, previous, following)
        text, start, finish = sentence.source_text.to_s.strip, sentence.start.to_f, sentence.finish.to_f
        return if text.empty? || finish <= start || finish - start > max_duration

        Selection.new(
          start: start, duration: finish - start, text: text, confidence: confidence(sentence),
          before: room(previous ? start - previous.finish.to_f : start * 2),
          after:  room(following ? following.start.to_f - finish : EDGE_ROOM * 2)
        )
      end

      # Half the silence to the neighbouring sentence, so two cuts never meet.
      def room(gap) = (gap / 2).clamp(0.0, EDGE_ROOM)

      def confidence(sentence)
        probabilities = Array(sentence.source_words).filter_map(&:confidence)
        return if probabilities.empty?

        Utils::Stats.mean(probabilities) * ::VoiceReference::TranscriptQuality.p10(probabilities)
      end

      def confident?(selection) = selection.confidence.nil? || selection.confidence >= MIN_CONFIDENCE

      def alone?(speaker_id, selection)
        finish = selection.start + selection.duration
        @segments.none? do |segment|
          next false if segment.speaker_id == speaker_id

          [finish, segment.finish].min - [selection.start, segment.start].max > OVERLAP_TOLERANCE
        end
      end
    end
  end
end
