require 'spec_helper'
require_relative '../lib/voice_separator'

RSpec.describe VoiceSeparator do
  it 'uses Demucs as the default backend' do
    expect(described_class::BACKEND).to eq(described_class::Demucs)
  end

  it 'removes temporary stems after the caller finishes' do
    paths = nil
    allow(described_class::BACKEND).to receive(:separate) do |_path, dir:|
      vocals = File.join(dir, 'vocals.wav')
      non_vocals = File.join(dir, 'no_vocals.wav')
      File.write(vocals, 'vocals')
      File.write(non_vocals, 'non-vocals')
      described_class::Stems.new(vocals: vocals, non_vocals: non_vocals)
    end

    described_class.with_stems('/tmp/input.mp4') do |stems|
      paths = [stems.vocals, stems.non_vocals]
      expect(paths).to all(satisfy { |path| File.exist?(path) })
    end

    expect(paths).to all(satisfy { |path| !File.exist?(path) })
  end
end
