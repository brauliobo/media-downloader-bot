require 'spec_helper'
require_relative '../../lib/dubbing/audio'

RSpec.describe Dubbing::Audio do
  let(:dir) { Dir.mktmpdir('dub-audio-spec-') }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def ok_status
    instance_double(Process::Status, success?: true)
  end

  it 'preserves synthesized edge padding without changing speech speed' do
    input = File.join(dir, 'input.wav')
    output = File.join(dir, 'output.wav')
    File.write(input, 'audio')

    expect(Sh).to receive(:run) do |command|
      expect(command).not_to include('atempo')
      expect(command).not_to include('atrim')
      expect(command).not_to include('silenceremove', 'afade')
      expect(command).to include('-ac 1 -ar 48000')
      File.write(output, 'normalized')
      ['', '', ok_status]
    end

    expect(described_class.normalize(input, output)).to eq(output)
  end

  it 'fits speech to its subtitle slot independently of the next sentence' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.5)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 1.0, end: 4.0)
    allow(Prober).to receive(:for).with(first.path).and_return(SymMash.new(format: SymMash.new(duration: 2.4)))
    allow(Prober).to receive(:for).with(second.path).and_return(SymMash.new(format: SymMash.new(duration: 2.0)))

    scheduled = described_class.schedule([first, second], duration: 5.0)

    expect(scheduled.map(&:start)).to eq([0.0, 1.0])
    expect(scheduled.first.end).to eq(1.5)
    expect(scheduled.first.speed).to be_within(0.001).of(2.4 / 1.5)
    expect(scheduled.last.speed).to eq(2.0 / 3.0)
  end

  it 'stretches shorter speech to the source sentence span' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 2.0)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 3.0, end: 4.0)
    allow(Prober).to receive(:for).with(first.path).and_return(SymMash.new(format: SymMash.new(duration: 1.0)))
    allow(Prober).to receive(:for).with(second.path).and_return(SymMash.new(format: SymMash.new(duration: 2.0)))

    scheduled = described_class.schedule([first, second], duration: 5.0)

    expect(scheduled.first.speed).to eq(0.5)
    expect(scheduled.first.end).to eq(2.0)
  end

  it 'uses the required speed even when it exceeds the former ceiling' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.0)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 2.0, end: 4.0)
    allow(Prober).to receive(:for).with(first.path).and_return(SymMash.new(format: SymMash.new(duration: 4.0)))
    allow(Prober).to receive(:for).with(second.path).and_return(SymMash.new(format: SymMash.new(duration: 2.0)))

    scheduled = described_class.schedule([first, second], duration: 5.0)

    expect(scheduled.first.speed).to eq(4.0)
    expect(scheduled.first.end).to eq(1.0)
    expect(scheduled.last.start).to eq(2.0)
  end

  it 'normalizes the rendered dialogue mix to broadcast speech loudness' do
    input = File.join(dir, 'input.wav')
    output = File.join(dir, 'output.wav')
    clip = described_class::Clip.new(path: input, start: 0.0, end: 2.0)
    File.write(input, 'audio')
    allow(Prober).to receive(:for).with(input).and_return(SymMash.new(format: SymMash.new(duration: 1.5)))
    expect(Sh).to receive(:run) do |command|
      expect(command).to include('amix\=inputs\=1:normalize\=0', 'loudnorm\=I\=-18:TP\=-1.5:LRA\=7')
      expect(command).to include('atempo\\=0.750000')
      File.write(output, 'mixed')
      ['', '', ok_status]
    end

    described_class.render_timeline([clip], output, duration: 3.0)
  end

  it 'replaces source audio instead of mixing it under the dub' do
    output = File.join(dir, 'output.mp4')
    expect(Sh).to receive(:run) do |command|
      expect(command).to include('-map 0:v:0 -map 1:a:0')
      expect(command).not_to include('sidechaincompress')
      expect(command).not_to include('amix')
      File.write(output, 'video')
      ['', '', ok_status]
    end

    described_class.replace_video_audio('video.mp4', 'dub.wav', output, duration: 6.0)
  end
end
