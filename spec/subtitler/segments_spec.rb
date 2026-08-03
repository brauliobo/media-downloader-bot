require 'spec_helper'

RSpec.describe Subtitler::Segments do
  def segment(text, start, finish, words: [], speaker_id: nil)
    SymMash.new(text: text, start: start, end: finish, words: words, speaker_id: speaker_id)
  end

  it 'merges adjacent segments and their word timings' do
    left  = segment('Hello', 0.0, 0.8, words: [SymMash.new(word: 'Hello')])
    right = segment('world', 1.0, 1.6, words: [SymMash.new(word: 'world')])
    mash  = SymMash.new(segments: [left, right])

    described_class.merge_adjacent!(mash)

    expect(mash.segments.map(&:text)).to eq(['Hello world'])
    expect(mash.segments.first.end).to eq(1.6)
    expect(mash.segments.first.words.map(&:word)).to eq(%w[Hello world])
  end

  it 'keeps segments separate at gap and length boundaries' do
    distant = SymMash.new(segments: [segment('one', 0.0, 1.0), segment('two', 2.1, 3.0)])
    long    = SymMash.new(segments: [segment('1234', 0.0, 1.0), segment('5678', 1.1, 2.0)])

    described_class.merge_adjacent!(distant, gap_threshold: 1.0)
    described_class.merge_adjacent!(long, max_chars: 8)

    expect(distant.segments.size).to eq(2)
    expect(long.segments.size).to eq(2)
  end

  it 'keeps adjacent segments from different speakers separate' do
    mash = SymMash.new(segments: [
      segment('Hello', 0.0, 0.8, speaker_id: 0),
      segment('world', 1.0, 1.6, speaker_id: 1),
    ])

    described_class.merge_adjacent!(mash)

    expect(mash.segments.map(&:text)).to eq(%w[Hello world])
  end
end
