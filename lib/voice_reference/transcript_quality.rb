class VoiceReference
  module TranscriptQuality
    module_function

    def words(value)
      value.to_s.downcase.scan(/[[:alpha:]]+/)
    end

    def word_similarity(expected, observed)
      left  = words(expected)
      right = words(observed)
      return 0 if left.empty? || right.empty?

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
      previous.last.fdiv([left.size, right.size].max)
    end

    def word_confidences(entry)
      unless entry.is_a?(Subtitler::Subtitle::Entry)
        raise TypeError, 'entry must be a Subtitler::Subtitle::Entry'
      end

      confidences = entry.words.filter_map(&:confidence)
      return confidences unless confidences.empty?
      return [] unless entry.metadata.key?('avg_logprob')

      Array.new(words(entry.text).size, Math.exp(entry.metadata.fetch('avg_logprob').to_f))
    end
  end
end
