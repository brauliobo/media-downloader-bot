require 'fileutils'

module Dubbing
  # Cuts each speaker's recorded TTS::Reference out of the original vocals. Dubbing always clones these, never an Anchor.
  #
  # The backend keeps the voice from the reference, so it is built with care: the clearest and most confidently
  # transcribed sentences that no other speaker talks over (Candidates), cut in the silence between words (Cutter),
  # joined by a short pause and brought to a steady loudness (Extractor).
  module VoiceReference
    MAX_DURATION  = 8.0
    # Silence after each clip, so words of different sentences do not run together.
    REFERENCE_GAP = 0.15

    # +before+ and +after+ are how far each cut may move outward, into the silence around the sentence.
    Selection = Data.define(:start, :duration, :text, :confidence, :before, :after, :clean, :score) do
      def initialize(confidence: nil, before: 0.0, after: 0.0, clean: true, score: 0.0, **attributes)
        super(confidence: confidence, before: before, after: after, clean: clean, score: score, **attributes)
      end
    end

    module_function

    def extract_by_speaker(input_path, segments, sentences:, dir:, **options)
      Extractor.new(input_path, segments: segments, sentences: sentences, dir: dir, **options).call
    end

    def extract_span(input_path, span, dir, idx, filter: FFmpeg.fade_filter(span.duration), pad_duration: REFERENCE_GAP)
      out = File.join(dir, format('speaker-%04d.wav', idx))
      ::VoiceReference::AudioAnalyzer.new.extract_span(
        audio:        input_path,
        start:        span.start,
        duration:     span.duration,
        output:       out,
        sample_rate:  22_050,
        filter:       filter,
        pad_duration: pad_duration,
      )

      out
    end
  end
end
