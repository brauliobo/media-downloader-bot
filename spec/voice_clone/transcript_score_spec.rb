require 'spec_helper'
require_relative '../../lib/voice_clone/transcript_score'

RSpec.describe VoiceClone::TranscriptScore do
  it 'scores matching text and word confidence' do
    result = described_class.new(language: 'pt', minimum_similarity: 0.8).call(
      expected: 'Olá mundo.',
      transcript: {
        language: 'pt',
        segments: [{text: 'Olá mundo.', probabilities: [0.9, 0.8]}]
      }
    )

    expect(result).to include(
      accepted: true,
      language_match: true,
      expected_words: 2,
      recognized_words: 2,
      matching_words: 2,
      match_rate: 1.0,
      word_error_rate: 0.0,
      recognized_word_confidence_p10: 0.8,
      transcription: 'Olá mundo.'
    )
  end

  it 'reports language mismatch and transcription errors' do
    result = described_class.new(language: 'pt').call(
      expected: 'The reference sentence.',
      transcript: {
        language: 'en',
        segments: [{text: 'A different phrase.', probabilities: [0.9]}]
      }
    )

    expect(result[:accepted]).to be(false)
    expect(result[:language_match]).to be(false)
    expect(result[:word_error_rate]).to be > 0
  end
end
