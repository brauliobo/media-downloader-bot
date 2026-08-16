require_relative '../subtitler/subtitle'
require_relative '../voice_reference/transcript_quality'

class VoiceClone
  class TranscriptScore
    def initialize(language: nil, minimum_similarity: 0.0)
      @language            = language&.to_s
      @minimum_similarity = minimum_similarity.to_f
    end

    def call(expected:, transcript:)
      raise TypeError, 'transcript must be a Subtitler::Subtitle' unless transcript.is_a?(Subtitler::Subtitle)

      observed = transcript.entries.map { |entry| entry.text.strip }.reject(&:empty?).join(' ')
      expected_words = VoiceReference::TranscriptQuality.words(expected)
      observed_words = VoiceReference::TranscriptQuality.words(observed)
      probabilities = transcript.entries.flat_map { |entry| VoiceReference::TranscriptQuality.word_confidences(entry) }
      detected_language = transcript.language&.to_s
      similarity = VoiceReference::TranscriptQuality.word_similarity(expected, observed)
      language_match = @language.nil? || detected_language == @language

      {
        accepted:                         language_match && similarity >= @minimum_similarity,
        language:                         detected_language,
        language_match:                   language_match,
        expected_words:                   expected_words.size,
        recognized_words:                 observed_words.size,
        matching_words:                   longest_common_subsequence(expected_words, observed_words),
        match_rate:                       similarity,
        word_error_rate:                  edit_distance(expected_words, observed_words).fdiv([expected_words.size, 1].max),
        recognized_word_confidence_mean:  mean(probabilities),
        recognized_word_confidence_p10:   percentile(probabilities, 0.1),
        transcription:                    observed,
        minimum_similarity:               @minimum_similarity,
      }
    end

    private

    def mean(values)
      values.empty? ? nil : values.sum.fdiv(values.size)
    end

    def percentile(values, ratio)
      return nil if values.empty?

      values.sort[[(values.size * ratio).floor, values.size - 1].min]
    end

    def longest_common_subsequence(left, right)
      previous = Array.new(right.size + 1, 0)
      left.each do |word|
        current = [0]
        right.each_with_index do |other, index|
          current << if word == other
            previous[index] + 1
          else
            [previous[index + 1], current[index]].max
          end
        end
        previous = current
      end
      previous.last
    end

    def edit_distance(left, right)
      previous = (0..right.size).to_a
      left.each_with_index do |word, left_index|
        current = [left_index + 1]
        right.each_with_index do |other, right_index|
          current << if word == other
            previous[right_index]
          else
            [previous[right_index], previous[right_index + 1], current[right_index]].min + 1
          end
        end
        previous = current
      end
      previous.last
    end
  end
end
