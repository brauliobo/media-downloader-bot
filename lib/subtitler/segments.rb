class Subtitler
  module Segments
    module_function

    def merge_adjacent!(mash, max_chars: 84, gap_threshold: 1.0, respect_speaker: true)
      segments = Array(mash.segments)
      return mash if segments.empty?

      merged  = []
      current = segments.first

      segments.drop(1).each do |segment|
        if mergeable?(current, segment, max_chars, gap_threshold, respect_speaker: respect_speaker)
          merge!(current, segment)
        else
          merged << current
          current = segment
        end
      end

      mash.segments = merged << current
      mash
    end

    def mergeable?(left, right, max_chars, gap_threshold, respect_speaker: true)
      return false if respect_speaker && different_speakers?(left, right)

      gap      = right.start.to_f - left.end.to_f
      combined = left.text.to_s.length + 1 + right.text.to_s.length
      gap <= gap_threshold && combined <= max_chars
    end

    def different_speakers?(left, right)
      left_speaker  = left[:speaker_id]
      right_speaker = right[:speaker_id]
      !left_speaker.nil? && !right_speaker.nil? && left_speaker != right_speaker
    end

    def merge!(left, right)
      left.text = [left.text, right.text].map { |text| text.to_s.strip }.reject(&:empty?).join(' ')
      left.end  = right.end
      left.words ||= []
      left.words.concat(Array(right.words))
    end
  end
end
