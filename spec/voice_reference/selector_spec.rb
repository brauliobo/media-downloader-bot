require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::Selector do
  let(:analyzer) do
    instance_double(VoiceReference::AudioAnalyzer).tap do |value|
      allow(value).to receive(:assess) do |candidate|
        quality = candidate.audio == 'clean.webm' ? 0.9 : 0.2
        candidate.score = quality + candidate.confidence * 0.2
        candidate
      end
    end
  end

  it 'selects intelligible English speech with the strongest signal quality' do
    selector = described_class.new(analyzer: analyzer)
    selected = selector.select([
      recording('clean.webm', probability: 0.92),
      recording('noisy.webm', probability: 0.99)
    ])

    expect(selected.audio).to eq('clean.webm')
    expect(selected.text).to include('clear English reference passage')
  end

  it 'rejects non-English and repetitive Whisper hallucinations' do
    selector = described_class.new(analyzer: analyzer)
    repetitive = Array.new(20, 'the same words').join(' ')
    selected = selector.select([
      recording('non-english.webm', language: 'hi', probability: 0.99),
      recording('repetitive.webm', probability: 0.99, text: repetitive)
    ])

    expect(selected).to be_nil
  end

  it 'requires typed transcripts' do
    expect do
      described_class.new(analyzer: analyzer).rank([{audio: 'legacy.wav', transcript: {language: 'en'}}])
    end.to raise_error(TypeError, 'transcript must be a Subtitler::Subtitle')
  end

  it 'uses entry avg_logprob when word confidence is unavailable' do
    text = 'Clear amber voices carry distinct phrases across quiet mountain valleys.'
    entry = Subtitler::Subtitle::Entry.new(
      start: 0, finish: 8, text: text, words: [], metadata: {'avg_logprob' => -0.01}
    )

    selected = described_class.new(analyzer: analyzer).select([
      {audio: 'clean.webm', transcript: subtitle(entry)}
    ])

    expect(selected).not_to be_nil
    expect(selected.confidence).to be_within(0.0001).of(Math.exp(-0.02))
  end

  it 'combines adjacent Whisper segments into a reference-length passage' do
    selector = described_class.new(analyzer: analyzer)
    transcript = subtitle(
        segment(0, 4, 'The supreme goal is the hub of the universe'),
        segment(4, 8, 'that controls everything and is above movements.'),
        segment(8, 30, 'This segment falls beyond the maximum reference duration and must not be included.')
    )

    selected = selector.select([{audio: 'clean.webm', transcript: transcript}])

    expect(selected.start).to eq(0)
    expect(selected.finish).to eq(8)
    expect(selected.text).to eq(
      'The supreme goal is the hub of the universe that controls everything and is above movements.'
    )
  end

  it 'does not append the next sentence to a complete reference passage' do
    selector = described_class.new(analyzer: analyzer)
    transcript = subtitle(
        segment(0, 4, 'This clean reference sentence begins with enough distinct words'),
        segment(4, 8, 'and reaches a natural ending.'),
        segment(8, 10, 'Unrelated closing words follow immediately afterward.')
    )

    selected = selector.select([{audio: 'clean.webm', transcript: transcript}])

    expect(selected.finish).to eq(8)
    expect(selected.text).not_to include('Unrelated')
  end

  it 'caps selected passages at eight seconds' do
    selector = described_class.new(analyzer: analyzer)
    transcript = subtitle(segment(0, 9, 'This passage is clear but exceeds the maximum reference duration.'))

    expect(selector.select([{audio: 'clean.webm', transcript: transcript}])).to be_nil
  end

  it 'compares complete passages from each recording instead of global confidence leaders' do
    selector = described_class.new(analyzer: analyzer)
    noisy_segments = 6.times.map do |index|
      segment(index * 9, index * 9 + 8, "Sentence #{index} has enough distinct English words for candidate selection.")
    end
    noisy_segments = noisy_segments.map do |entry|
      segment(entry.start, entry.finish, entry.text, probability: 0.99)
    end

    selected = selector.select([
      {audio: 'noisy.webm', transcript: subtitle(*noisy_segments)},
      recording('clean.webm', probability: 0.9)
    ])

    expect(selected.audio).to eq('clean.webm')
  end

  it 'keeps all candidate windows when quality validation is deferred' do
    analyzer = instance_double(VoiceReference::AudioAnalyzer)
    allow(analyzer).to receive(:measure) do |candidate|
      candidate.score = candidate.start
      candidate
    end
    selector = described_class.new(analyzer: analyzer, strict: false)
    sentences = [
      'Bright amber foxes explore distant valleys beyond winter mountains.',
      'Calm bronze herons circle hidden rivers beneath early morning sunlight.',
      'Quiet crimson boats cross narrow channels beside ancient stone villages.',
      'Silver desert winds carry fragrant cedar pollen toward coastal gardens.',
      'Violet lanterns illuminate winding paths through remote hillside orchards.',
      'Golden autumn clouds gather above peaceful fields near northern forests.',
    ]
    segments = sentences.each_with_index.map do |text, index|
      segment(index * 9, index * 9 + 8, text)
    end

    ranked = selector.rank([{audio: 'source.webm', transcript: subtitle(*segments)}])

    expect(ranked.size).to eq(6)
  end

  it 'rejects passages that start or end inside a sentence' do
    selector = described_class.new(analyzer: analyzer)
    transcript = subtitle(
        segment(0, 15, 'The sentence begins here with several distinct words and continues,'),
        segment(15, 25, 'then it may create something good or something bad for the universe.')
    )

    expect(selector.select([{audio: 'clean.webm', transcript: transcript}])).to be_nil
  end

  it 'trims a low-confidence leading clause from an otherwise clean passage' do
    selector = described_class.new(analyzer: analyzer)
    weak = segment(0, 7, 'Due to geographical conditions,', probabilities: [0.1, 0.95, 0.95])
    transcript = subtitle(
        weak,
        segment(7, 10, 'due to historical facts,'),
        segment(10, 14, 'there are differences in color.')
    )

    selected = selector.select([{audio: 'clean.webm', transcript: transcript}])

    expect(selected.start).to eq(7)
    expect(selected.finish).to eq(14)
    expect(selected.text).to eq('due to historical facts, there are differences in color.')
  end

  it 'rejects a passage when trimming its noisy ending leaves an incomplete phrase' do
    selector = described_class.new(analyzer: analyzer)
    weak = segment(7, 12, 'good parties.', probabilities: [0.1, 0.95])
    transcript = subtitle(
        segment(0, 7, 'But for providing security to good ideas, good thoughts and'),
        weak
    )

    expect(selector.select([{audio: 'clean.webm', transcript: transcript}])).to be_nil
  end

  def recording(audio, language: 'en', probability:, text: nil)
    text ||= 'This clear English reference passage contains enough distinct words for reliable reuse.'
    {
      audio: audio,
      transcript: subtitle(segment(0, 8, text, probability: probability), language: language)
    }
  end

  def subtitle(*entries, language: 'en')
    Subtitler::Subtitle.new(language: language, entries: entries)
  end

  def segment(start, finish, text, probability: 0.95, probabilities: nil, metadata: {})
    probabilities ||= Array.new(text.split.size, probability)
    words = text.split.zip(probabilities).map do |word, confidence|
      Subtitler::Subtitle::Word.new(
        text: word, start: start, finish: finish, confidence: confidence
      )
    end
    Subtitler::Subtitle::Entry.new(
      start: start,
      finish: finish,
      text: text,
      words: words,
      metadata: metadata
    )
  end
end
