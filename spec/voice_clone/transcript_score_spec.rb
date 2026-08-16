require 'spec_helper'
require_relative '../../lib/voice_clone/transcript_score'

RSpec.describe VoiceClone::TranscriptScore do
  it 'scores matching text and word confidence' do
    result = described_class.new(language: 'pt', minimum_similarity: 0.8).call(
      expected: 'Olá mundo.',
      transcript: subtitle('Olá mundo.', language: 'pt', probabilities: [0.9, 0.8])
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
      transcript: subtitle('A different phrase.', language: 'en', probabilities: [0.9])
    )

    expect(result[:accepted]).to be(false)
    expect(result[:language_match]).to be(false)
    expect(result[:word_error_rate]).to be > 0
  end

  it 'requires a typed subtitle' do
    expect do
      described_class.new.call(expected: 'Text.', transcript: {language: 'en', segments: []})
    end.to raise_error(TypeError, 'transcript must be a Subtitler::Subtitle')
  end

  it 'uses avg_logprob confidence for each lexical word when words have no confidence' do
    entry = Subtitler::Subtitle::Entry.new(
      start: 0, finish: 1, text: 'Two words.', metadata: {'avg_logprob' => Math.log(0.8)}
    )
    result = described_class.new.call(
      expected: 'Two words.', transcript: Subtitler::Subtitle.new(language: 'en', entries: [entry])
    )

    expect(result[:recognized_word_confidence_mean]).to be_within(0.0001).of(0.8)
    expect(result[:recognized_word_confidence_p10]).to be_within(0.0001).of(0.8)
  end

  def subtitle(text, language:, probabilities:)
    words = text.split.zip(probabilities.cycle).map do |word, confidence|
      Subtitler::Subtitle::Word.new(text: word, start: 0, finish: 1, confidence: confidence)
    end
    Subtitler::Subtitle.new(
      language: language,
      entries: [Subtitler::Subtitle::Entry.new(start: 0, finish: 1, text: text, words: words)]
    )
  end
end
