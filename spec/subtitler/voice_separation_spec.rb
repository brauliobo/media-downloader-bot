require 'spec_helper'

RSpec.describe Subtitler do
  it 'transcribes the separated vocal stem by default' do
    stems = VoiceSeparator::Stems.new(vocals: '/tmp/vocals.wav', non_vocals: '/tmp/no-vocals.wav')
    allow(VoiceSeparator).to receive(:with_stems).and_yield(stems)
    expect(described_class).to receive(:transcribe_with_backend)
      .with(stems.vocals, format: 'verbose_json')
      .and_return(:transcript)

    expect(described_class.transcribe('/tmp/input.mp4', format: 'verbose_json')).to eq(:transcript)
  end

  it 'can reuse an already separated vocal stem' do
    expect(VoiceSeparator).not_to receive(:with_stems)
    expect(described_class).to receive(:transcribe_with_backend)
      .with('/tmp/vocals.wav', format: 'verbose_json')
      .and_return(:transcript)

    expect(described_class.transcribe(
      '/tmp/vocals.wav', format: 'verbose_json', separate_voice: false
    )).to eq(:transcript)
  end
end
