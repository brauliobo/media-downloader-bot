require 'rails_helper'

RSpec.describe Subtitler::DroppedSpeech do
  def entry(text, start, finish) = Subtitler::Subtitle::Entry.new(text: text, start: start, finish: finish)

  def subtitle(*entries) = Subtitler::Subtitle.new(language: 'uk', text: 'x', entries: entries)

  def speech(*spans)
    ranges = Utils::TimeRanges.new(spans.map { |start, finish| Utils::TimeRanges::Interval.new(start: start, finish: finish) }, option: :vad)
    allow(VoiceActivity).to receive(:detect).with('audio.wav').and_return(ranges)
  end

  let(:before) { entry('before', 0.0, 6.0) }
  let(:after)  { entry('after', 31.0, 35.0) }

  it 'transcribes again from its start a gap that has speech, keeping what fits in it' do
    speech([0.0, 27.0], [31.0, 35.0])
    gaps = []
    result = described_class.new(subtitle(before, after), audio: 'audio.wav') do |gap|
      gaps << gap
      subtitle(entry('middle one', 6.1, 18.0), entry('middle two', 18.0, 30.0), entry('repeat of after', 30.0, 33.0))
    end.call

    expect(gaps).to eq([described_class::Gap.new(6.0, 31.0)])
    expect(result.entries.map(&:text)).to eq(['before', 'middle one', 'middle two', 'after'])
    expect(result.text).to eq('before middle one middle two after')
  end

  it 'leaves a gap without speech alone, however much speech surrounds it' do
    speech([0.0, 6.0], [7.0, 7.5], [31.0, 35.0], [40.0, 50.0])

    described_class.new(subtitle(before, after), audio: 'audio.wav') { raise 'transcribed' }.call
  end

  it 'leaves a short gap alone without asking for the speech' do
    expect(VoiceActivity).not_to receive(:detect)

    described_class.new(subtitle(before, entry('close', 7.0, 9.0)), audio: 'audio.wav') { raise 'transcribed' }.call
  end

  it 'tries a gap once when nothing is found in it' do
    speech([0.0, 35.0])
    calls = 0

    result = described_class.new(subtitle(before, after), audio: 'audio.wav') { calls += 1; subtitle }.call

    expect(calls).to eq(1)
    expect(result.entries.map(&:text)).to eq(%w[before after])
  end

  it 'drops a phrase the transcription looped on and transcribes its stretch again' do
    speech([0.0, 35.0])
    looped = [entry('Do you feel it?', 6.0, 7.0), entry('do you feel it', 7.0, 8.0), entry('Do you feel it!', 8.0, 9.0)]
    gaps   = []

    result = described_class.new(subtitle(before, *looped, after), audio: 'audio.wav') do |gap|
      gaps << gap
      subtitle(entry('what was said', 10.0, 20.0))
    end.call

    expect(gaps.first).to eq(described_class::Gap.new(6.0, 31.0))
    expect(result.entries.map(&:text)).to eq(['before', 'what was said', 'after'])
  end

  it 'keeps a phrase said twice' do
    speech([0.0, 35.0])
    twice = [entry('Do you feel it?', 6.0, 7.0), entry('Do you feel it?', 7.0, 8.0)]

    result = described_class.new(subtitle(before, *twice, after), audio: 'audio.wav') { subtitle }.call

    expect(result.entries.map(&:text)).to eq(['before', 'Do you feel it?', 'Do you feel it?', 'after'])
  end

  it 'drops an entry that is one phrase repeated' do
    speech([0.0, 35.0])
    repeated = entry('I know her, ' * 12, 6.0, 20.0)

    result = described_class.new(subtitle(before, repeated, after), audio: 'audio.wav') { subtitle }.call

    expect(result.entries.map(&:text)).to eq(%w[before after])
  end
end
