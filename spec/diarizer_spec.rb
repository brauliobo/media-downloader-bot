require 'spec_helper'
require_relative '../lib/diarizer'

RSpec.describe Diarizer do
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

  it 'rejects transcript sentences with no diarization overlap' do
    sentence = SymMash.new(start: 10.0, end: 11.0)
    speaker = SymMash.new(start: 0.0, end: 1.0, speaker_id: 0)

    expect { described_class.assign_speakers!([sentence], [speaker]) }
      .to raise_error(/no diarization overlap/)
  end
end
