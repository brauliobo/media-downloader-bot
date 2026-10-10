require 'json'

class Diarizer
  Result = Data.define(:segments) do
    def initialize(segments:)
      super(segments: segments.dup.freeze)
    end

    def self.from_json(input)
      data     = JSON.parse(input)
      segments = data.fetch('segments').map do |segment|
        Segment.new(
          start:      segment.fetch('start'),
          finish:     segment.fetch('end'),
          speaker_id: segment.fetch('speaker_id')
        )
      end
      new(segments: segments)
    rescue JSON::ParserError, KeyError, NoMethodError, TypeError
      raise ArgumentError, 'diarization returned malformed speaker segments'
    end
  end
end
