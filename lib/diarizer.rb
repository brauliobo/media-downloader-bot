require_relative 'diarizer/pyannote_community1'
require_relative 'diarizer/sherpa_onnx'
require_relative 'diarizer/tiny_diarize'

class Diarizer
  BACKEND = const_get(ENV['DIARIZER'] || 'SherpaOnnx')

  def self.diarize(path, speakers: nil)
    BACKEND.diarize(path, speakers: speakers)
  end

  def self.assign_speakers!(sentences, speaker_segments)
    segments = Array(speaker_segments)
    raise 'diarization returned no speaker segments' if segments.empty?

    Array(sentences).each do |sentence|
      segment, overlap = segments.map do |candidate|
        start  = [sentence.start.to_f, candidate.start.to_f].max
        finish = [sentence.end.to_f, candidate.end.to_f].min
        [candidate, [finish - start, 0.0].max]
      end.max_by(&:last)

      raise "no diarization overlap for sentence at #{sentence.start}-#{sentence.end}" unless overlap.positive?

      sentence.speaker_id = segment.speaker_id
    end
  end
end
