require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::AudioAnalyzer do
  it 'applies the full voice-quality filter when extracting the reference' do
    candidate = VoiceReference::Candidate.new(
      audio: 'source.webm', start: 10, finish: 17,
      text: 'A clean recorded phrase.', confidence: 0.95
    )
    status = instance_double(Process::Status)
    command = nil
    allow(Sh).to receive(:run) do |value|
      command = value
      ['', '', status]
    end
    allow(Sh).to receive(:assert_success!)

    described_class.new.extract(candidate, '/tmp/reference.wav')

    filter  = command.fetch(command.index('-af') + 1)
    expect(filter).to start_with(Zipper::VOICE_QUALITY_FILTER)
  end
end
