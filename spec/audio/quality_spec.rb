require 'spec_helper'
require_relative '../../lib/audio'

RSpec.describe Audio::Quality do
  it 'reports reusable signal, loudness, silence, thresholds, and acceptance' do
    status = instance_double(Process::Status)
    allow(Sh).to receive(:assert_success!)
    allow(Sh).to receive(:run) do |command|
      joined = command.join(' ')
      case joined
      when /astats=/
        ['', <<~OUTPUT, status]
          Peak level dB: -3.0
          RMS level dB: -18.0
          Entropy: 0.8
          Zero crossings rate: 0.04
          Bit depth: 16/16/16/16
        OUTPUT
      when /ebur128=/
        ['', "Summary:\nI: -18.0 LUFS\nLRA: 2.0 LU\nPeak: -3.0 dBFS\n", status]
      when /silencedetect=/
        ['', 'silence_duration: 0.5', status]
      when /ffprobe/
        ["10.0\n", '', status]
      else
        raise "unexpected command: #{joined}"
      end
    end

    report = described_class.new.report('/tmp/reference.wav')

    expect(report).to include(
      accepted: true, duration: 10.0, integrated_lufs: -18.0,
      loudness_range_lu: 2.0, true_peak_db: -3.0, silence_ratio: 0.05
    )
    expect(report[:thresholds]).to include(max_true_peak_db: -1.5, min_bit_depth: 14)
  end
end
