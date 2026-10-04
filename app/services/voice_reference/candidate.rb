class VoiceReference
  Candidate = Struct.new(
    :audio, :start, :finish, :text, :confidence, :metrics, :score, :validation, :artifacts,
    keyword_init: true
  ) do
    def duration = finish - start

    def to_h
      {
        audio:      audio,
        start:      start,
        finish:     finish,
        duration:   duration,
        text:       text,
        confidence: confidence,
        metrics:    metrics,
        score:      score,
        validation: validation,
        artifacts:  artifacts
      }
    end
  end
end
