require 'spec_helper'
require_relative '../../lib/audio'

RSpec.describe Audio::ReferenceQuality do
  let(:strong_metrics) do
    {
      peak_db: -3.0, rms_db: -18.0, entropy: 0.85, zero_crossing_rate: 0.04, bit_depth: 16,
      estimated_noise_floor_db: -45.0, estimated_snr_db: 27.0, leading_rms_db: -40.0,
      trailing_rms_db: -40.0, duration: 60.0, integrated_lufs: -18.0, loudness_range_lu: 4.0,
      true_peak_db: -3.0, silence_seconds: 1.2, silence_ratio: 0.02, issues: [], accepted: true,
      thresholds: {},
    }
  end

  it 'reports a transparent reference-suitability score from shared quality metrics' do
    quality = instance_double(Audio::Quality, report: strong_metrics)

    report = described_class.new(quality: quality).report('/tmp/voice.wav', metadata: {title: 'Voice'})

    expect(report).to include(title: 'Voice', score: 90.38, grade: 'excellent', accepted: true)
    expect(report[:components].keys).to eq(described_class::COMPONENT_WEIGHTS.keys)
    expect(report[:metrics]).to equal(strong_metrics)
  end

  it 'ranks cleaner recordings above noisy, clipped recordings' do
    weak_metrics = strong_metrics.merge(
      entropy: 0.56, zero_crossing_rate: 0.14, bit_depth: 10,
      estimated_noise_floor_db: -21.0, estimated_snr_db: 9.0,
      silence_ratio: 0.3, integrated_lufs: -6.0, loudness_range_lu: 14.0,
      true_peak_db: 0.0, accepted: false,
    )
    quality = instance_double(Audio::Quality)
    allow(quality).to receive(:report).with('/tmp/strong.wav').and_return(strong_metrics)
    allow(quality).to receive(:report).with('/tmp/weak.wav').and_return(weak_metrics)

    ranked = described_class.new(quality: quality).rank(['/tmp/weak.wav', '/tmp/strong.wav'])

    expect(ranked.map { |record| File.basename(record[:path]) }).to eq(%w[strong.wav weak.wav])
    expect(ranked.last[:grade]).to eq('poor')
  end

  it 'shares candidate signal scoring with voice-reference selection' do
    metrics = {entropy: 0.8, zero_crossing_rate: 0.04, rms_db: -18.0}

    expect(described_class.signal_score(metrics)).to be_within(0.0001).of(0.62)
  end
end
