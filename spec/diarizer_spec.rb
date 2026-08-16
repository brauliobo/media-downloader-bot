require 'spec_helper'
require_relative '../lib/diarizer'

RSpec.describe Diarizer do
  it 'defaults to the pyannote Community-1 backend' do
    expect(described_class::BACKEND).to eq(Diarizer::PyannoteCommunity1)
  end

  it 'assigns each sentence to the speaker segment with the greatest overlap' do
    sentences = [
      Subtitler::Subtitle::Entry.new(start: 0.0, finish: 2.0),
      Subtitler::Subtitle::Entry.new(start: 2.0, finish: 4.0),
    ]
    speakers = [
      Diarizer::Segment.new(start: 0.0, finish: 1.5, speaker_id: 3),
      Diarizer::Segment.new(start: 1.5, finish: 4.0, speaker_id: 8),
    ]

    described_class.assign_speakers!(sentences, speakers)

    expect(sentences.map(&:speaker_id)).to eq([3, 8])
  end

  it 'assigns a sentence to the nearest speaker when diarization has a gap' do
    sentence = Subtitler::Subtitle::Entry.new(start: 10.0, finish: 11.0)
    speakers = [
      Diarizer::Segment.new(start: 0.0, finish: 1.0, speaker_id: 0),
      Diarizer::Segment.new(start: 5.0, finish: 6.0, speaker_id: 1),
    ]

    described_class.assign_speakers!([sentence], speakers)

    expect(sentence.speaker_id).to eq(1)
  end

  it 'rejects empty diarization output' do
    expect { described_class.assign_speakers!([], []) }
      .to raise_error(/no speaker segments/)
  end

  it 'rejects subtitle hashes instead of mutating them' do
    expect { described_class.assign_speakers!([{start: 0.0, end: 1.0}], []) }
      .to raise_error(TypeError, /Subtitle::Entry/)
  end
end
