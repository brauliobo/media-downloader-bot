require 'spec_helper'
require_relative '../../lib/audio'

RSpec.describe Audio::Quality do
  it 'leaves FFmpeg analysis labels under FFmpeg' do
    expect(described_class.const_defined?(:TOOLS, false)).to be false
    expect(FFmpeg::TOOLS).to be_frozen
  end

  it 'reports reusable signal, loudness, silence, thresholds, and acceptance' do
    ffmpeg = instance_double FFmpeg
    levels = [-80, -44, -40, -32, -28, -24, -22, -20, -18, -80]
    allow(ffmpeg).to receive(:analyze_audio).with('/tmp/reference.wav', kind: :signal).and_return([
      '', <<~OUTPUT
        Peak level dB: -3.0
        RMS level dB: -18.0
        Entropy: 0.8
        Zero crossings rate: 0.04
        Bit depth: 16/16/16/16
      OUTPUT
    ])
    allow(ffmpeg).to receive(:analyze_audio).with('/tmp/reference.wav', kind: :frame_signal).and_return([
      levels.map { |level| "lavfi.astats.Overall.RMS_level=#{level}" }.join("\n"), ''
    ])
    allow(ffmpeg).to receive(:analyze_audio).with('/tmp/reference.wav', kind: :loudness).and_return([
      '', "Summary:\nI: -18.0 LUFS\nLRA: 2.0 LU\nPeak: -3.0 dBFS\n"
    ])
    allow(ffmpeg).to receive(:analyze_audio).with(
      '/tmp/reference.wav', kind: :silence, silence_threshold_db: -35
    ).and_return ['', 'silence_duration: 0.5']
    allow(ffmpeg).to receive(:audio_duration).with('/tmp/reference.wav').and_return 10.0

    report = described_class.new(ffmpeg: ffmpeg).report('/tmp/reference.wav')

    expect(report).to include(
      accepted: true, duration: 10.0, integrated_lufs: -18.0,
      loudness_range_lu: 2.0, true_peak_db: -3.0, silence_ratio: 0.05,
      estimated_noise_floor_db: -44.0, estimated_snr_db: 26.0,
      leading_rms_db: -80.0, trailing_rms_db: -80.0, issues: []
    )
    expect(report[:thresholds]).to include(
      max_true_peak_db: -1.5, min_bit_depth: 14,
      max_estimated_noise_floor_db: -30.0, min_estimated_snr_db: 12.0,
      max_edge_rms_db: -35.0
    )
  end

  it 'preserves FFmpeg analysis errors and labels' do
    ffmpeg = instance_double FFmpeg
    error  = Sh::Error.new 'audio signal analysis failed', 'invalid audio'
    allow(ffmpeg).to receive(:analyze_audio).with('/tmp/broken.wav', kind: :signal).and_raise error

    expect {
      described_class.new(ffmpeg: ffmpeg).signal '/tmp/broken.wav'
    }.to raise_error Sh::Error, 'audio signal analysis failed: invalid audio'
  end

  it 'returns structured errors and warnings for automation' do
    report = {
      peak_db:                  -3.0,
      rms_db:                   -18.0,
      entropy:                  0.8,
      zero_crossing_rate:       0.04,
      bit_depth:                16,
      integrated_lufs:          -18.0,
      loudness_range_lu:        2.0,
      true_peak_db:             -3.0,
      silence_ratio:            0.05,
      estimated_noise_floor_db: -23.0,
      estimated_snr_db:         7.0,
      leading_rms_db:           -20.0,
      trailing_rms_db:          -18.0
    }

    issues = described_class.new.diagnose(report)

    expect(issues.map { |issue| issue[:code] }).to eq(%w[
      background_noise low_estimated_snr active_leading_edge active_trailing_edge
    ])
    expect(issues.first).to eq(
      code:      'background_noise',
      severity:  'error',
      metric:    'estimated_noise_floor_db',
      observed:  -23.0,
      threshold: {maximum: -30.0}
    )
    expect(issues.last[:severity]).to eq('warning')
  end
end
