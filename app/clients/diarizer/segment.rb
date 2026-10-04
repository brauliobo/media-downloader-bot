class Diarizer
  Segment = Data.define(:start, :finish, :speaker_id) do
    def initialize(start:, finish:, speaker_id:)
      start  = Float(start)
      finish = Float(finish)
      valid  = start.finite? && finish.finite? && finish > start && speaker_id.present?
      raise ArgumentError, 'diarization returned malformed speaker segments' unless valid

      super(start: start, finish: finish, speaker_id: speaker_id)
    rescue TypeError, ArgumentError
      raise ArgumentError, 'diarization returned malformed speaker segments'
    end
  end
end
