require 'spec_helper'
require_relative '../lib/diarizer'

RSpec.describe Diarizer do
  it 'defaults to the pyannote Community-1 backend' do
    expect(described_class::BACKEND).to eq(Diarizer::PyannoteCommunity1)
  end

  it 'assigns each sentence to the speaker segment with the greatest overlap' do
    sentences = [
      SymMash.new(start: 0.0, end: 2.0),
      SymMash.new(start: 2.0, end: 4.0),
    ]
    speakers = [
      SymMash.new(start: 0.0, end: 1.5, speaker_id: 3),
      SymMash.new(start: 1.5, end: 4.0, speaker_id: 8),
    ]

    described_class.assign_speakers!(sentences, speakers)

    expect(sentences.map(&:speaker_id)).to eq([3, 8])
  end

  it 'assigns a sentence to the nearest speaker when diarization has a gap' do
    sentence = SymMash.new(start: 10.0, end: 11.0)
    speakers = [
      SymMash.new(start: 0.0, end: 1.0, speaker_id: 0),
      SymMash.new(start: 5.0, end: 6.0, speaker_id: 1),
    ]

    described_class.assign_speakers!([sentence], speakers)

    expect(sentence.speaker_id).to eq(1)
  end

  it 'rejects empty diarization output' do
    expect { described_class.assign_speakers!([], []) }
      .to raise_error(/no speaker segments/)
  end
end
