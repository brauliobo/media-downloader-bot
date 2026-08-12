require 'spec_helper'
require_relative '../../lib/dubbing/audio'
require_relative '../../lib/subtitler/translator'

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

  it 'uses the gap after a sentence before speeding it up' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.5)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 2.0, end: 4.0)
    allow(Prober).to receive(:for).with(first.path).and_return(SymMash.new(format: SymMash.new(duration: 2.4)))
    allow(Prober).to receive(:for).with(second.path).and_return(SymMash.new(format: SymMash.new(duration: 2.0)))

    scheduled = described_class.schedule([first, second], duration: 5.0)

    expect(scheduled.map(&:start)).to eq([0.0, 2.0])
    expect(scheduled.first.end).to eq(2.0)
    expect(scheduled.first.speed).to be_within(0.001).of(2.4 / 2.0)
    expect(scheduled.last.speed).to eq(1.0)
  end

  it 'keeps shorter speech at its natural speed' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 2.0)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 3.0, end: 4.0)
    allow(Prober).to receive(:for).with(first.path).and_return(SymMash.new(format: SymMash.new(duration: 1.0)))
    allow(Prober).to receive(:for).with(second.path).and_return(SymMash.new(format: SymMash.new(duration: 2.0)))

    scheduled = described_class.schedule([first, second], duration: 5.0)

    expect(scheduled.first.speed).to eq(1.0)
    expect(scheduled.first.end).to eq(1.0)
  end

  it 'keeps every sentence from a multi-sentence subtitle at or above natural speed' do
    subtitle = SymMash.new(text: 'First sentence. Second sentence.', start: 1.0, end: 5.0, words: [])
    sentences = Subtitler::Translator.sentences_for([subtitle])
    clips = sentences.map.with_index do |sentence, idx|
      described_class::Clip.new(path: File.join(dir, "sentence-#{idx}.wav"), start: sentence.start, end: sentence.end)
    end
    clips.each do |clip|
      allow(Prober).to receive(:for).with(clip.path).and_return(SymMash.new(format: SymMash.new(duration: 0.5)))
    end

    scheduled = described_class.schedule(clips, duration: 6.0)

    expect(sentences.size).to eq(2)
    expect(scheduled.map(&:speed)).to all(be >= 1.0)
  end

  it 'rejects scheduled clips below natural speed' do
    expect do
      described_class::ScheduledClip.new(path: 'speech.wav', start: 0.0, end: 2.0, speed: 0.5)
    end.to raise_error(ArgumentError, 'dubbed speech speed cannot be below 1x')
  end

  it 'rejects rendering below natural speed' do
    expect { described_class.tempo_filter(0.5) }
      .to raise_error(ArgumentError, 'dubbed speech speed cannot be below 1x')
  end

  it 'uses gaps before and after a sentence to avoid speeding it up' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.0)
    middle = described_class::Clip.new(path: File.join(dir, 'middle.wav'), start: 2.0, end: 3.0)
    last = described_class::Clip.new(path: File.join(dir, 'last.wav'), start: 4.0, end: 5.0)
    allow(Prober).to receive(:for).with(first.path).and_return(SymMash.new(format: SymMash.new(duration: 1.0)))
    allow(Prober).to receive(:for).with(middle.path).and_return(SymMash.new(format: SymMash.new(duration: 3.0)))
    allow(Prober).to receive(:for).with(last.path).and_return(SymMash.new(format: SymMash.new(duration: 1.0)))

    scheduled = described_class.schedule([first, middle, last], duration: 5.0)

    expect(scheduled.map(&:speed)).to eq([1.0, 1.0, 1.0])
    expect(scheduled[1].start).to eq(1.0)
    expect(scheduled[1].end).to eq(4.0)
  end

  it 'shares a gap between neighboring sentences without overlapping them' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.0)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 2.0, end: 3.0)
    allow(Prober).to receive(:for).with(first.path).and_return(SymMash.new(format: SymMash.new(duration: 3.0)))
    allow(Prober).to receive(:for).with(second.path).and_return(SymMash.new(format: SymMash.new(duration: 3.0)))

    scheduled = described_class.schedule([first, second], duration: 3.0)

    expect(scheduled.map(&:speed)).to eq([2.0, 2.0])
    expect(scheduled.first.end).to eq(1.5)
    expect(scheduled.last.start).to eq(1.5)
  end

  it 'uses the required speed even when it exceeds the former ceiling' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.0)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 2.0, end: 4.0)
    allow(Prober).to receive(:for).with(first.path).and_return(SymMash.new(format: SymMash.new(duration: 4.0)))
    allow(Prober).to receive(:for).with(second.path).and_return(SymMash.new(format: SymMash.new(duration: 2.0)))

    scheduled = described_class.schedule([first, second], duration: 5.0)

    expect(scheduled.first.speed).to eq(2.0)
    expect(scheduled.first.end).to eq(2.0)
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
      expect(command).not_to include('atempo')
      File.write(output, 'mixed')
      ['', '', ok_status]
    end

    described_class.render_timeline([clip], output, duration: 3.0)
  end

  it 'mixes the non-vocal stem under generated speech' do
    output = File.join(dir, 'output.mp4')
    expect(Sh).to receive(:run) do |command|
      expect(command).to include('-i dub.wav -i no-vocals.wav')
      expect(command).to include('amix\=inputs\=2:normalize\=0', '-map 0:v:0 -map [a]')
      expect(command).not_to include('-map 1:a:0')
      File.write(output, 'video')
      ['', '', ok_status]
    end

    described_class.replace_video_audio('video.mp4', 'dub.wav', 'no-vocals.wav', output, duration: 6.0)
  end
end
