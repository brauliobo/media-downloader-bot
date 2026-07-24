class VoiceReference
  class Selector
    DURATION_RANGE             = 8.0..20.0
    WORD_RANGE                 = 10..35
    MIN_RECORDING_UNIQUE_RATIO = 0.85
    MIN_AVERAGE_PROBABILITY    = 0.85
    MIN_P10_PROBABILITY        = 0.65
    MAX_CANDIDATES_PER_RECORDING = 5

    def initialize(language: 'en', analyzer: AudioAnalyzer.new)
      @language = language
      @analyzer = analyzer
    end

    def select(recordings)
      candidates = Array(recordings).flat_map do |recording|
        transcript_candidates(recording.fetch(:audio), recording.fetch(:transcript))
          .sort_by { |candidate| -candidate.confidence }
          .first(MAX_CANDIDATES_PER_RECORDING)
      end
      candidates.filter_map { |candidate| analyzer.assess(candidate) }
        .max_by(&:score)
    end

    private

    attr_reader :language, :analyzer

    def transcript_candidates(audio, transcript)
      return [] unless transcript.fetch(:language) == language
      return [] if unique_trigram_ratio(transcription_text(transcript)) < MIN_RECORDING_UNIQUE_RATIO

      segment_windows(transcript.fetch(:segments)).filter_map do |segments|
        start  = segments.first.fetch(:start).to_f
        finish = segments.last.fetch(:finish).to_f
        text   = segments.map { |segment| segment.fetch(:text).strip }.join(' ')
        words  = text.scan(/[[:alpha:]]+/)
        next unless DURATION_RANGE.cover?(finish - start) && WORD_RANGE.cover?(words.size)

        probabilities = segments.flat_map { |segment| segment.fetch(:probabilities) }
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

    def segment_windows(segments)
      segments = Array(segments)
      segments.each_index.flat_map do |start_index|
        next [] unless start_index.zero? || sentence_ending?(segments[start_index - 1])

        window = []
        windows = []
        segments.drop(start_index).each do |segment|
          window << segment
          duration = window.last.fetch(:finish).to_f - window.first.fetch(:start).to_f
          break if duration > DURATION_RANGE.max

          windows << window.dup if duration >= DURATION_RANGE.min && sentence_ending?(segment)
        end
        windows
      end
    end

    def sentence_ending?(segment)
      segment.fetch(:text).strip.end_with?('.', '?', '!')
    end

    def transcription_text(transcript)
      transcript.fetch(:segments).map { |segment| segment.fetch(:text) }.join(' ')
    end

    def unique_trigram_ratio(text)
      trigrams = text.downcase.scan(/[[:alpha:]]+/).each_cons(3).to_a
      trigrams.empty? ? 0 : trigrams.uniq.size.fdiv(trigrams.size)
    end
  end
end
