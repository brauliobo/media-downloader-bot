require 'spec_helper'

RSpec.describe Subtitler::Subtitle, 'segment normalization' do
  def word(text, start, finish)
    Subtitler::Subtitle::Word.new(text: text, start: start, finish: finish)
  end

  def segment(text, start, finish, words: [], speaker_id: nil)
    Subtitler::Subtitle::Entry.new(
      text: text, start: start, finish: finish, words: words, speaker_id: speaker_id
    )
  end

  it 'merges adjacent segments and their word timings' do
    left     = segment('Hello', 0.0, 0.8, words: [word('Hello', 0.0, 0.8)])
    right    = segment('world', 1.0, 1.6, words: [word('world', 1.0, 1.6)])
    subtitle = Subtitler::Subtitle.new(entries: [left, right])

    subtitle.merge_adjacent!

    expect(subtitle.entries.map(&:text)).to eq(['Hello world'])
    expect(subtitle.entries.first.finish).to eq(1.6)
    expect(subtitle.entries.first.words.map(&:text)).to eq(%w[Hello world])
  end

  it 'keeps segments separate at gap and length boundaries' do
    distant = Subtitler::Subtitle.new(entries: [segment('one', 0.0, 1.0), segment('two', 2.1, 3.0)])
    long    = Subtitler::Subtitle.new(entries: [segment('1234', 0.0, 1.0), segment('5678', 1.1, 2.0)])

    distant.merge_adjacent!(gap_threshold: 1.0)
    long.merge_adjacent!(max_chars: 8)

    expect(distant.entries.size).to eq(2)
    expect(long.entries.size).to eq(2)
  end

  it 'keeps adjacent segments from different speakers separate' do
    subtitle = Subtitler::Subtitle.new(entries: [
      segment('Hello', 0.0, 0.8, speaker_id: 0),
      segment('world', 1.0, 1.6, speaker_id: 1),
    ])

    subtitle.merge_adjacent!

    expect(subtitle.entries.map(&:text)).to eq(%w[Hello world])
  end
end
