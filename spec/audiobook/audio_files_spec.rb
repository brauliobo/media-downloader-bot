require 'rails_helper'

RSpec.describe Audiobook::AudioFiles do
  def sine_wav(path, rate: 24_000, seconds: 1)
    system('ffmpeg', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', "sine=frequency=440:sample_rate=#{rate}:duration=#{seconds}", '-c:a', 'pcm_s16le', path) || raise('sine fixture failed')
  end

  def duration(path) = Prober.for(path).format.duration.to_f

  around { |example| Dir.mktmpdir('audio-files-') { |dir| @dir = dir; example.run } }

  let(:wav) { File.join(@dir, '1_0.wav').tap { |path| sine_wav(path) } }

  it 'stores a wav as a much smaller Opus file and drops the wav' do
    size = File.size(wav)
    stored = described_class.compress(wav)

    expect(stored).to eq File.join(@dir, '1_0.opus')
    expect(File.exist?(wav)).to be(false)
    expect(File.size(stored)).to be < size / 3
    expect(duration(stored)).to be_within(0.1).of(1)
    expect(Dir.children(@dir)).to eq ['1_0.opus']
  end

  it 'speeds the audio up in the same pass' do
    expect(duration(described_class.compress(wav, speed: 2))).to be_within(0.15).of(0.5)
  end

  it 'joins stored and plain parts into a wav of the book sample rate' do
    stored = described_class.compress(wav)
    pause  = File.join(@dir, 'pause.wav').tap { |path| sine_wav(path, seconds: 0.5) }
    joined = described_class.join([pause, stored], File.join(@dir, 'joined.wav'), consumed: [stored])

    expect(Prober.audio_signature(joined)[:sample_rate].to_i).to eq described_class.sample_rate
    expect(duration(joined)).to be_within(0.15).of(1.5)
    expect(File.exist?(stored)).to be(false)
  end
end
