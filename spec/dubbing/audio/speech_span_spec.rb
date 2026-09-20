require 'spec_helper'
require_relative '../../../lib/dubbing/audio/speech_span'

RSpec.describe Dubbing::Audio::SpeechSpan do
  it 'treats silence from the start of the file as leading pad' do
    stderr = <<~LOG
      silence_start: 0
      silence_end: 0.210 | silence_duration: 0.210
      silence_start: 1.20
      silence_end: 1.35 | silence_duration: 0.150
    LOG

    span = described_class.parse(stderr, 2.0)

    expect(span.leading).to be_within(0.001).of(0.210)
    expect(span.trailing).to eq(0.0)
    expect(span.speech).to be_within(0.001).of(1.790)
  end

  it 'treats silence that runs to EOF as trailing pad' do
    stderr = <<~LOG
      silence_start: 0
      silence_end: 0.200 | silence_duration: 0.200
      silence_start: 1.80
      silence_end: 2.00 | silence_duration: 0.200
    LOG

    span = described_class.parse(stderr, 2.0)

    expect(span.leading).to be_within(0.001).of(0.200)
    expect(span.trailing).to be_within(0.001).of(0.200)
    expect(span.speech).to be_within(0.001).of(1.600)
  end

  it 'does not count interior pauses as trailing pad' do
    stderr = <<~LOG
      silence_start: 0
      silence_end: 0.1245 | silence_duration: 0.1245
      silence_start: 0.753458
      silence_end: 0.989375 | silence_duration: 0.235917
      silence_start: 4.11
      silence_end: 4.213375 | silence_duration: 0.103375
    LOG

    span = described_class.parse(stderr, 6.32)

    expect(span.leading).to be_within(0.001).of(0.1245)
    expect(span.trailing).to eq(0.0)
    expect(span.speech).to be_within(0.001).of(6.1955)
  end

  it 'keeps the full file when there is no usable speech' do
    stderr = <<~LOG
      silence_start: 0
      silence_end: 3.0 | silence_duration: 3.0
    LOG

    span = described_class.parse(stderr, 3.0)

    expect(span).to have_attributes(leading: 0.0, trailing: 0.0, speech: 3.0, duration: 3.0)
  end

  it 'keeps the full file when no silence is reported' do
    span = described_class.parse('', 1.5)

    expect(span).to have_attributes(leading: 0.0, trailing: 0.0, speech: 1.5)
  end
end
