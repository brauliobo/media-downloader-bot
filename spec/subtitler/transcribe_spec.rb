require 'spec_helper'

RSpec.describe Subtitler do
  def ranges(*pairs)
    Utils::TimeRanges.new(
      pairs.map { |start, finish| Utils::TimeRanges::Interval.new(start: start, finish: finish) },
      option: :vad
    )
  end

  it 'transcribes concatenated Silero speech ranges by default' do
    detected = ranges([1.0, 3.0])
    transcript = Subtitler::Subtitle.new(language: 'en')
    remapped = Subtitler::Subtitle.new(language: 'en')
    allow(VoiceActivity).to receive(:with_speech).and_yield('/tmp/speech.wav', detected)
    expect(described_class).to receive(:transcribe_with_backend)
      .with('/tmp/speech.wav')
      .and_return(transcript)
    expect(VoiceActivity).to receive(:restore_timing!).with(transcript, detected).and_return(remapped)

    expect(described_class.transcribe('/tmp/input.mp4')).to equal(remapped)
    expect(VoiceActivity).to have_received(:with_speech).with('/tmp/input.mp4')
  end

  it 'reports voice detection before transcription' do
    transcript = Subtitler::Subtitle.new(language: 'pt')
    stl = instance_double('StatusLine', update: nil)
    allow(VoiceActivity).to receive(:with_speech).and_yield('/tmp/speech.wav', ranges([0.1, 1.2]))
    allow(described_class).to receive(:transcribe_with_backend).with('/tmp/speech.wav').and_return(transcript)
    allow(VoiceActivity).to receive(:restore_timing!).and_return(transcript)

    expect(described_class.transcribe('/tmp/input.mp4', stl: stl)).to equal(transcript)
    expect(stl).to have_received(:update).with('detecting voice').ordered
    expect(stl).to have_received(:update).with('transcribing').ordered
  end

  it 'skips Whisper when Silero finds no speech' do
    allow(VoiceActivity).to receive(:with_speech).and_yield(nil, ranges)
    expect(described_class).not_to receive(:transcribe_with_backend)

    expect(described_class.transcribe('/tmp/input.mp4')).to have_attributes(language: nil, text: '', entries: [])
  end

  it 'transcribes Demucs vocals without Silero VAD' do
    transcript = Subtitler::Subtitle.new(language: 'en')
    expect(VoiceActivity).not_to receive(:with_speech)
    expect(described_class).to receive(:transcribe_with_backend)
      .with('/tmp/vocals.wav')
      .and_return(transcript)

    expect(described_class.transcribe_vocals('/tmp/vocals.wav')).to equal(transcript)
  end
end
