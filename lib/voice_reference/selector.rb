class VoiceReference
  class Selector
    DURATION_RANGE               = 4.0..14.0
    WORD_RANGE                   = 10..35
    MIN_RECORDING_UNIQUE_RATIO   = 0.85
    MIN_AVERAGE_PROBABILITY      = 0.85
    MIN_P10_PROBABILITY          = 0.75
    MIN_EDGE_P10_PROBABILITY     = 0.6
    MAX_REFERENCE_DURATION        = 8.0
    REFINED_DURATION_RANGE       = 4.0..MAX_REFERENCE_DURATION
    REFINED_WORD_RANGE           = 8..35
    MAX_CANDIDATES_PER_RECORDING = 5

    def initialize(language: 'en', analyzer: AudioAnalyzer.new, strict: true)
      @language = language
      @analyzer = analyzer
      @strict   = strict
    end

    def select(recordings)
      rank(recordings).first
    end

    def rank(recordings)
      candidates = Array(recordings).flat_map do |recording|
        candidates = transcript_candidates(recording.fetch(:audio), recording.fetch(:transcript))
          .sort_by { |candidate| -candidate.confidence }
        strict ? candidates.first(MAX_CANDIDATES_PER_RECORDING) : candidates
      end
      candidates.filter_map { |candidate| analyzer.public_send(strict ? :assess : :measure, candidate) }
        .sort_by { |candidate| -candidate.score }
    end

    private

    attr_reader :language, :analyzer, :strict

    def transcript_candidates(audio, transcript)
      raise TypeError, 'transcript must be a Subtitler::Subtitle' unless transcript.is_a?(Subtitler::Subtitle)
      return [] unless transcript.language == language
      return [] if unique_trigram_ratio(transcription_text(transcript)) < MIN_RECORDING_UNIQUE_RATIO

      segment_windows(transcript.entries).filter_map do |segments|
        segments = trim_noisy_edge_segments(segments)
        next unless segments

        start  = segments.first.start.to_f
        finish = segments.last.finish.to_f
        text   = segments.map { |segment| segment.text.strip }.join(' ')
        words  = text.scan(/[[:alpha:]]+/)
        next unless REFINED_DURATION_RANGE.cover?(finish - start) && REFINED_WORD_RANGE.cover?(words.size)

        probabilities = segments.flat_map { |segment| TranscriptQuality.word_confidences(segment) }
        next if probabilities.empty?

        average = probabilities.sum / probabilities.size
        p10     = probabilities.sort[(probabilities.size * 0.1).floor]
        next if average < MIN_AVERAGE_PROBABILITY || p10 < MIN_P10_PROBABILITY

        Candidate.new(
          audio: audio, start: start, finish: finish, text: text,
          confidence: average * p10
        )
      end
    end

    def trim_noisy_edge_segments(segments)
      trimmed = segments.drop_while { |segment| noisy_edge?(segment) }
      trimmed.pop while trimmed.any? && noisy_edge?(trimmed.last)
      trimmed if trimmed.any? && sentence_ending?(trimmed.last)
    end

    def noisy_edge?(segment)
      segment_p10_probability(segment) < MIN_EDGE_P10_PROBABILITY
    end

    def segment_p10_probability(segment)
      probabilities = TranscriptQuality.word_confidences(segment).sort
      return 0 if probabilities.empty?

      probabilities[(probabilities.size * 0.1).floor]
    end

    def segment_windows(segments)
      segments = Array(segments)
      segments.each_index.flat_map do |start_index|
        next [] unless start_index.zero? || sentence_ending?(segments[start_index - 1])

        window = []
        windows = []
        segments.drop(start_index).each do |segment|
          window << segment
          duration = window.last.finish.to_f - window.first.start.to_f
          break if duration > DURATION_RANGE.max

          if duration >= DURATION_RANGE.min && sentence_ending?(segment)
            windows << window.dup
            break
          end
        end
        windows
      end
    end

    def sentence_ending?(segment)
      segment.text.strip.end_with?('.', '?', '!')
    end

    def transcription_text(transcript)
      transcript.entries.map(&:text).join(' ')
    end

    def unique_trigram_ratio(text)
      trigrams = text.downcase.scan(/[[:alpha:]]+/).each_cons(3).to_a
      trigrams.empty? ? 0 : trigrams.uniq.size.fdiv(trigrams.size)
    end
  end
end
