require 'spec_helper'
require_relative '../lib/diarizer'

RSpec.describe Diarizer do
  def subtitle(*entries, text: nil, metadata: {})
    Subtitler::Subtitle.new(entries: entries, text: text, metadata: metadata)
  end

  def entry(text:, start:, finish:, words: [], **options)
    Subtitler::Subtitle::Entry.new(text: text, start: start, finish: finish, words: words, **options)
  end

  def word(text, start, finish, metadata: {})
    Subtitler::Subtitle::Word.new(text: text, start: start, finish: finish, metadata: metadata)
  end

  def segment(start, finish, speaker_id)
    Diarizer::Segment.new(start: start, finish: finish, speaker_id: speaker_id)
  end

  it 'defaults to the pyannote Community-1 backend' do
    expect(described_class::BACKEND).to eq(Diarizer::PyannoteCommunity1)
  end

  it 'assigns wordless entries by greatest overlap and returns the subtitle' do
    document = subtitle(
      Subtitler::Subtitle::Entry.new(start: 0.0, finish: 2.0),
      Subtitler::Subtitle::Entry.new(start: 2.0, finish: 4.0)
    )
    speakers = [segment(0.0, 1.5, 3), segment(1.5, 4.0, 8)]

    result = described_class.assign_speakers!(document, speakers)

    expect(result).to equal(document)
    expect(document.entries.map(&:speaker_id)).to eq([3, 8])
    expect(document.entries.map(&:words)).to eq([[], []])
  end

  it 'assigns a wordless entry to the nearest speaker when diarization has a gap' do
    document = subtitle(entry(text: 'Gap.', start: 10.0, finish: 11.0))
    speakers = [segment(0.0, 1.0, 0), segment(5.0, 6.0, 1)]

    described_class.assign_speakers!(document, speakers)

    expect(document.entries.first).to have_attributes(text: 'Gap.', start: 10.0, finish: 11.0, speaker_id: 1)
    expect(document.entries.first.words).to be_empty
  end

  it 'splits timed words into contiguous speaker runs and preserves typed entry state' do
    words = [
      word('Hello', 0.0, 0.8, metadata: {'confidence_source' => 'whisper'}),
      word('there,', 0.8, 1.4),
      word('friend.', 1.4, 2.0),
    ]
    document = subtitle(
      entry(
        text: 'stale transcript text', start: 0.0, finish: 2.0, words: words,
        cue_id: 'cue-7', source_text: 'Hello there, friend.', source_words: words.map(&:deep_copy),
        metadata: {'nested' => {'value' => 3}}
      ),
      text: 'stale document text', metadata: {'document' => true}
    )
    original_words = document.entries.first.words

    described_class.assign_speakers!(document, [segment(0.0, 1.0, 'A'), segment(1.0, 2.0, 'B')])

    expect(document.entries.map { |item| [item.text, item.start, item.finish, item.speaker_id] }).to eq([
      ['Hello', 0.0, 0.8, 'A'],
      ['there, friend.', 0.8, 2.0, 'B'],
    ])
    expect(document.entries.map(&:cue_id)).to eq(%w[cue-7 cue-7])
    expect(document.entries.map(&:metadata)).to all(eq('nested' => {'value' => 3}))
    expect(document.entries.map(&:source_text)).to eq(['Hello', 'there, friend.'])
    expect(document.entries.map { |item| item.source_words.map(&:text) }).to eq([['Hello'], ['there,', 'friend.']])
    expect(document.entries.flat_map(&:words).map(&:object_id) & original_words.map(&:object_id)).to be_empty
    expect(document.text).to eq('Hello there, friend.')
    expect(document.metadata).to eq('document' => true)
  end

  it 'uses the nearest segment for timed words in gaps' do
    document = subtitle(entry(
      text: 'Left right', start: 1.0, finish: 5.0,
      words: [word('Left', 1.5, 2.0), word('right', 4.0, 4.5)]
    ))

    described_class.assign_speakers!(document, [segment(0.0, 1.0, 'A'), segment(5.0, 6.0, 'B')])

    expect(document.entries.map { |item| [item.text, item.speaker_id] }).to eq([['Left', 'A'], ['right', 'B']])
  end

  it 'does not split across adjacent diarization segments for the same speaker' do
    document = subtitle(entry(
      text: 'Still speaking', start: 0.0, finish: 2.0,
      words: [word('Still', 0.0, 1.0), word('speaking', 1.0, 2.0)]
    ))

    described_class.assign_speakers!(document, [segment(0.0, 1.0, 'A'), segment(1.0, 2.0, 'A')])

    expect(document.entries).to contain_exactly(have_attributes(text: 'Still speaking', speaker_id: 'A'))
  end

  it 'prefers the segment starting at an exact boundary when overlap and distance tie' do
    document = subtitle(entry(
      text: 'Boundary', start: 1.0, finish: 1.0,
      words: [word('Boundary', 1.0, 1.0)]
    ))

    described_class.assign_speakers!(document, [segment(0.0, 1.0, 'A'), segment(1.0, 2.0, 'B')])

    expect(document.entries.first.speaker_id).to eq('B')
  end

  it 'renders split entries without injecting speaker labels' do
    document = subtitle(entry(
      text: 'Hello goodbye', start: 0.0, finish: 2.0,
      words: [word('Hello', 0.0, 1.0), word('goodbye', 1.0, 2.0)]
    ))
    described_class.assign_speakers!(document, [segment(0.0, 1.0, 'speaker A'), segment(1.0, 2.0, 'speaker B')])

    vtt = document.to_vtt
    ass = document.to_ass(mode: :plain)

    expect(vtt.scan('-->').size).to eq(2)
    expect(ass.lines.grep(/^Dialogue:/).size).to eq(2)
    expect(vtt).not_to include('speaker A', 'speaker B')
    expect(ass).not_to include('speaker A', 'speaker B')
  end

  it 'rejects empty diarization output' do
    expect { described_class.assign_speakers!(subtitle, []) }
      .to raise_error(/no speaker segments/)
  end

  it 'rejects entry arrays instead of accepting an untyped document' do
    expect { described_class.assign_speakers!([entry(text: 'No.', start: 0.0, finish: 1.0)], []) }
      .to raise_error(TypeError, /Subtitler::Subtitle/)
  end
end
