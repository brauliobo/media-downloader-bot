require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::AudioAnalyzer do
  let(:ffmpeg) { instance_double FFmpeg }
  let(:analyzer) { described_class.new ffmpeg: ffmpeg }

  it 'injects FFmpeg and requests the exact raw reference extraction' do
    candidate = VoiceReference::Candidate.new(
      audio: 'source.webm', start: 10, finish: 17,
      text: 'A clean recorded phrase.', confidence: 0.95
    )
    expect(ffmpeg).to receive(:extract_audio).with(
      input:       'source.webm',
      output:      '/tmp/reference.wav',
      start:       10,
      duration:    7,
      filter:      nil,
      sample_rate: 24_000,
      channels:    1,
      label:       'voice reference extraction failed'
    ).and_return '/tmp/reference.wav'

    output = analyzer.extract candidate, '/tmp/reference.wav'

    expect(output).to eq '/tmp/reference.wav'
  end

  it 'delegates quality filter construction to FFmpeg' do
    filter = FFmpeg.voice_reference_filter(
      :quality, silence_threshold_db: described_class::SILENCE_THRESHOLD_DB
    )
    expect(FFmpeg).to receive(:voice_reference_filter).with(
      :quality,
      silence_threshold_db: described_class::SILENCE_THRESHOLD_DB,
      pad_duration: nil
    ).and_return filter
    expect(ffmpeg).to receive(:extract_audio).with(
      input:       'source.webm',
      output:      '/tmp/reference.wav',
      start:       10,
      duration:    4,
      filter:      filter,
      sample_rate: 24_000,
      channels:    1,
      label:       'voice reference extraction failed'
    )

    analyzer.extract_span(
      audio: 'source.webm', start: 10, duration: 4,
      output: '/tmp/reference.wav', filter: :quality
    )

    expect(described_class::FILTERS.fetch(:quality)).to eq filter
    expect(filter).to start_with "#{FFmpeg.voice_quality_filter},"
    expect(filter).to include 'silenceremove=', 'areverse', 'afade='
  end

  it 'measures candidates without applying strict signal rejection' do
    candidate = VoiceReference::Candidate.new(
      audio: 'source.webm', start: 10, finish: 17,
      text: 'A measurable recorded phrase.', confidence: 0.95
    )
    metrics = {peak_db: 0.0, rms_db: -18.0, entropy: 0.8, zero_crossing_rate: 0.04, bit_depth: 16}
    quality = instance_double(Audio::Quality, signal: metrics)
    analyzer = described_class.new quality: quality, ffmpeg: ffmpeg
    expect(ffmpeg).to receive(:extract_audio) do |arguments|
      output = arguments.fetch :output
      expect(arguments).to eq(
        input:       'source.webm',
        output:      output,
        start:       10,
        duration:    7,
        filter:      nil,
        sample_rate: 24_000,
        channels:    1,
        label:       'voice candidate extraction failed'
      )
      expect(output).to end_with 'candidate.wav'
    end

    measured = analyzer.measure(candidate)

    expect(measured.metrics).to equal(metrics)
    expect(measured.score).to be_within(0.0001).of(0.81)
  end

  it 'supports padded extraction at a caller-selected sample rate' do
    filter = FFmpeg.voice_reference_filter(
      :clone, silence_threshold_db: described_class::SILENCE_THRESHOLD_DB, pad_duration: 0.15
    )
    expect(FFmpeg).to receive(:voice_reference_filter).with(
      :clone,
      silence_threshold_db: described_class::SILENCE_THRESHOLD_DB,
      pad_duration: 0.15
    ).and_return filter
    expect(ffmpeg).to receive(:extract_audio).with(
      input:       'source.webm',
      output:      '/tmp/reference.wav',
      start:       10,
      duration:    4,
      filter:      filter,
      sample_rate: 22_050,
      channels:    1,
      label:       'voice reference extraction failed'
    )

    analyzer.extract_span(
      audio: 'source.webm', start: 10, duration: 4,
      output: '/tmp/reference.wav', sample_rate: 22_050, pad_duration: 0.15, filter: :clone
    )
  end

  it 'preserves caller-provided filters with padding' do
    expect(FFmpeg).to receive(:voice_reference_filter).with(
      :raw,
      silence_threshold_db: described_class::SILENCE_THRESHOLD_DB,
      pad_duration: 0.15
    ).and_call_original
    expect(ffmpeg).to receive(:extract_audio).with(
      input:       'source.webm',
      output:      '/tmp/reference.wav',
      start:       10,
      duration:    4,
      filter:      'highpass=f=80,apad=pad_dur=0.15',
      sample_rate: 24_000,
      channels:    1,
      label:       'voice reference extraction failed'
    )

    analyzer.extract_span(
      audio: 'source.webm', start: 10, duration: 4, output: '/tmp/reference.wav',
      filter: 'highpass=f=80', pad_duration: 0.15
    )
  end

  it 'propagates FFmpeg extraction failures' do
    failure = Sh::Error.new 'voice reference extraction failed', 'invalid audio'
    allow(ffmpeg).to receive(:extract_audio).and_raise failure

    expect {
      analyzer.extract_span audio: 'source.webm', start: 10, duration: 4, output: '/tmp/reference.wav'
    }.to raise_error failure
  end
end
