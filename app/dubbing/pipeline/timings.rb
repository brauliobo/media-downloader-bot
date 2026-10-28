module Dubbing
  class Pipeline
    # Speaking the translated sentences and fitting their timing to what was spoken.
    module Timings
      private

      # Translates and speaks the sentences; the ones with nothing to say are left out.
      def synthesize_timeline(workdir)
        synthesizer = SpeechSynthesizer.new(
          sentences:       @sentences,
          references:      @speaker_references,
          opts:            @opts,
          target_lang:     target_lang,
          workdir:         workdir,
          video_duration:  video_duration,
          translate:       method(:translate_sentence!),
          stl:             @stl
        )
        synthesizer.render.tap { replace_sentences!(synthesizer.sentences) }
      end

      def apply_scheduled_timings!(clips, spoken: nil)
        unless @sentences.size == clips.size
          raise "dubbed timeline clip count mismatch: expected #{@sentences.size}, got #{clips.size}"
        end

        spoken_words = Array(spoken&.entries).flat_map(&:words)
        scheduled = @sentences.zip(clips).filter_map do |sentence, clip|
          target_start    = clip.start.to_f
          target_end      = clip.end.to_f
          next unless target_end > target_start

          words = words_in_clip(spoken_words, target_start, target_end)
          if words.empty?
            sentence.retime!(start: target_start, finish: target_end)
          else
            align_sentence_to_speech!(sentence, words, fallback_start: target_start, fallback_end: target_end)
          end
          sentence
        end
        replace_sentences!(scheduled)
      end

      def transcribe_spoken_timeline(path)
        @stl&.update 'dubbing: aligning subtitles'
        Subtitler.transcribe_vocals(path)
      end

      def words_in_clip(words, start_time, end_time)
        words.select do |word|
          next if word.finish <= word.start

          midpoint = (word.start + word.finish) / 2.0
          midpoint >= start_time && midpoint < end_time
        end
      end

      def align_sentence_to_speech!(sentence, words, fallback_start:, fallback_end:)
        copies = words.map(&:deep_copy).filter_map do |word|
          start  = word.start.to_f.clamp(fallback_start, fallback_end)
          finish = word.finish.to_f.clamp(start, fallback_end)
          next if finish <= start

          word.retime!(start: start, finish: finish)
        end
        if copies.empty?
          sentence.retime!(start: fallback_start, finish: fallback_end)
          return sentence
        end

        sentence.retime!(start: copies.first.start, finish: copies.last.finish)
        sentence.replace_words!(copies)
        sentence.project_text!(sentence.text)
        sentence
      end
    end
  end
end
