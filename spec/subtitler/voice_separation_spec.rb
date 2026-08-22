require 'spec_helper'

RSpec.describe Subtitler do
  it 'transcribes the separated vocal stem by default' do
    stems = VoiceSeparator::Stems.new(vocals: '/tmp/vocals.wav', non_vocals: '/tmp/no-vocals.wav')
    transcript = Subtitler::Subtitle.new(language: 'en')
    allow(VoiceSeparator).to receive(:with_stems).and_yield(stems)
    expect(described_class).to receive(:transcribe_with_backend)
      .with(stems.vocals)
      .and_return(transcript)

    expect(described_class.transcribe('/tmp/input.mp4')).to equal(transcript)
    expect(VoiceSeparator).to have_received(:with_stems).with('/tmp/input.mp4')
  end

  it 'reports voice separation before transcription' do
    stems = VoiceSeparator::Stems.new(vocals: '/tmp/vocals.wav', non_vocals: '/tmp/no-vocals.wav')
    transcript = Subtitler::Subtitle.new(language: 'pt')
    stl = instance_double('StatusLine', update: nil)
    allow(VoiceSeparator).to receive(:with_stems).and_yield(stems)
    allow(described_class).to receive(:transcribe_with_backend).with(stems.vocals).and_return(transcript)

    expect(described_class.transcribe('/tmp/input.mp4', stl: stl)).to equal(transcript)
    expect(stl).to have_received(:update).with('separating voice').ordered
    expect(stl).to have_received(:update).with('transcribing').ordered
  end

  it 'can reuse an already separated vocal stem' do
    transcript = Subtitler::Subtitle.new(language: 'en')
    expect(VoiceSeparator).not_to receive(:with_stems)
    expect(described_class).to receive(:transcribe_with_backend)
      .with('/tmp/vocals.wav')
      .and_return(transcript)

    expect(described_class.transcribe('/tmp/vocals.wav', separate_voice: false)).to equal(transcript)
  end
end
