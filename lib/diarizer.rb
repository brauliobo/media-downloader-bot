require_relative 'diarizer/pyannote_community1'
require_relative 'diarizer/sherpa_onnx'
require_relative 'diarizer/tiny_diarize'

class Diarizer
  BACKEND = const_get(ENV['DIARIZER'] || 'PyannoteCommunity1')

  def self.diarize(path, speakers: nil)
    BACKEND.diarize(path, speakers: speakers)
  end

  def self.assign_speakers!(sentences, speaker_segments)
    segments = Array(speaker_segments)
    raise 'diarization returned no speaker segments' if segments.empty?

    Array(sentences).each do |sentence|
      segment = segments.max_by do |candidate|
        start   = [sentence.start.to_f, candidate.start.to_f].max
        finish  = [sentence.end.to_f, candidate.end.to_f].min
        overlap = [finish - start, 0.0].max
        distance = [
          candidate.start.to_f - sentence.end.to_f,
          sentence.start.to_f - candidate.end.to_f,
          0.0
        ].max
        [overlap, -distance]
      end
      sentence.speaker_id = segment.speaker_id
    end
  end
end
