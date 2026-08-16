require_relative 'diarizer/pyannote_community1'
require_relative 'diarizer/sherpa_onnx'
require_relative 'diarizer/tiny_diarize'
require_relative 'subtitler/subtitle'

class Diarizer
  BACKEND = const_get(ENV['DIARIZER'] || 'PyannoteCommunity1')

  def self.diarize(path, speakers: nil)
    BACKEND.diarize(path, speakers: speakers)
  end

  def self.assign_speakers!(sentences, speaker_segments)
    unless sentences.is_a?(Array) && sentences.all? { |sentence| sentence.is_a?(Subtitler::Subtitle::Entry) }
      raise TypeError, 'sentences must be an Array of Subtitler::Subtitle::Entry objects'
    end

    segments = Array(speaker_segments)
    raise 'diarization returned no speaker segments' if segments.empty?

    Array(sentences).each do |sentence|
      segment = segments.max_by do |candidate|
        start   = [sentence.start.to_f, candidate.start.to_f].max
        finish  = [sentence.finish.to_f, candidate.finish.to_f].min
        overlap = [finish - start, 0.0].max
        distance = [
          candidate.start.to_f - sentence.finish.to_f,
          sentence.start.to_f - candidate.finish.to_f,
          0.0
        ].max
        [overlap, -distance]
      end
      sentence.assign_speaker!(segment.speaker_id)
    end
  end
end
