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
    expect(filter).to eq(described_class::REFERENCE_FILTER)
    expect(filter).to include('silenceremove=', 'areverse', 'afade=')
  end

  it 'measures candidates without applying strict signal rejection' do
    candidate = VoiceReference::Candidate.new(
      audio: 'source.webm', start: 10, finish: 17,
      text: 'A measurable recorded phrase.', confidence: 0.95
    )
    metrics = {peak_db: 0.0, rms_db: -18.0, entropy: 0.8, zero_crossing_rate: 0.04, bit_depth: 16}
    quality = instance_double(Audio::Quality, signal: metrics)
    analyzer = described_class.new(quality: quality)
    allow(analyzer).to receive(:extract_raw)

    measured = analyzer.measure(candidate)

    expect(measured.metrics).to equal(metrics)
    expect(measured.score).to be_within(0.0001).of(0.81)
  end

  it 'supports padded extraction at a caller-selected sample rate' do
    status = instance_double(Process::Status, success?: true)
    command = nil
    allow(Sh).to receive(:run) do |value|
      command = value
      ['', '', status]
    end
    allow(Sh).to receive(:assert_success!)

    described_class.new.extract_span(
      audio: 'source.webm', start: 10, duration: 4,
      output: '/tmp/reference.wav', sample_rate: 22_050, pad_duration: 0.15
    )

    filter = command.fetch(command.index('-af') + 1)
    expect(filter).to include(described_class::REFERENCE_FILTER, 'apad=pad_dur=0.15')
    expect(command).to include('-ar', '22050')
  end
end
