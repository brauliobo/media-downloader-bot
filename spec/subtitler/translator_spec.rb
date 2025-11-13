require 'spec_helper'

RSpec.describe Subtitler::Translator do
  let(:backend) do
    Class.new do
      include Subtitler::WhisperCpp
    end.new
  end

  def word(text, s, e)
    { word: text, start: s, end: e }
  end

  it 'reconstructs sentences split across segments and translates properly' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 0.8, text: 'Hello world', words: [
          word('Hello', 0.0, 0.4),
          word('world', 0.4, 0.8)
        ]},
        { start: 0.9, end: 3.5, text: '! This is a test.', words: [
          word('!', 0.9, 0.9),
          word('This', 2.5, 2.7),
          word('is', 2.7, 2.8),
          word('a', 2.8, 2.85),
          word('test', 2.85, 3.4),
          word('.', 3.4, 3.5)
        ]}
      ]
    }

    allow(::Translator).to receive(:translate).and_return([
      'Olá mundo!',
      'Isto é um teste.'
    ])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')

    expect(mash.segments.size).to eq(2)
    expect(mash.segments[0].text).to eq('Olá mundo!')
    expect(mash.segments[1].text).to eq('Isto é um teste.')

    w0 = mash.segments[0].words
    expect(w0.map { |w| w.word }).to eq(['Olá', 'mundo!'])
    expect(w0.first.start).to eq(0.0)
    expect(w0.last.end).to eq(0.8)
    expect(mash.segments[0].start).to eq(0.0)
    expect(mash.segments[0].end).to eq(0.9) # preserves end from punctuation timing

    w1 = mash.segments[1].words
    expect(w1.map { |w| w.word }.join(' ')).to eq('Isto é um teste.')
    expect(mash.segments[1].start).to eq(2.5)
    expect(mash.segments[1].end).to eq(3.5)

    vtt = backend.send(:vtt_convert, mash, normalize: false, word_tags: false)
    expect(vtt).to eq(
      "WEBVTT\n\n" \
      "00:00:00.000 --> 00:00:00.900\n" \
      "Olá mundo!\n\n" \
      "00:00:02.500 --> 00:00:03.500\n" \
      "Isto é um teste.\n\n"
    )
  end

  it 'packs more translated tokens than source words across word slots' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 1.2, text: 'New York .', words: [
          word('New', 0.0, 0.4),
          word('York', 0.4, 0.9),
          word('.', 0.9, 1.2)
        ]}
      ]
    }

    allow(::Translator).to receive(:translate).and_return([
      'Nova Iorque, Estados Unidos.'
    ])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')
    expect(mash.segments.size).to eq(1)
    expect(mash.segments[0].text).to eq('Nova Iorque, Estados Unidos.')
    words = mash.segments[0].words
    expect(words.map { |w| w.word }).to eq(['Nova Iorque,', 'Estados', 'Unidos.'])
  end

  it 'drops extra source words when translation has fewer tokens' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 1.5, text: 'It is good .', words: [
          word('It', 0.0, 0.3),
          word('is', 0.3, 0.6),
          word('good', 0.6, 1.2),
          word('.', 1.2, 1.5)
        ]}
      ]
    }

    allow(::Translator).to receive(:translate).and_return([
      'É bom.'
    ])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')
    words = mash.segments[0].words
    expect(mash.segments[0].text).to eq('É bom.')
    expect(words.map { |w| w.word }).to eq(['É', 'bom.'])
  end

  it 'handles segments without words by translating text only' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 0.8, text: 'Hello.', words: nil },
        { start: 2.0, end: 3.0, text: 'Bye.', words: nil }
      ]
    }

    allow(::Translator).to receive(:translate).and_return([
      'Olá.', 'Tchau.'
    ])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')
    expect(mash.segments.size).to eq(2)
    expect(mash.segments.map(&:text)).to eq(['Olá.', 'Tchau.'])
    expect(mash.segments.all? { |s| Array(s.words).empty? }).to eq(true)
  end

  it 'merges adjacent short sentences into standard-length subtitle' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 0.8, text: 'Hi', words: [word('Hi', 0.0, 0.8)] },
        { start: 1.0, end: 1.6, text: 'there.', words: [word('there', 1.0, 1.5), word('.', 1.5, 1.6)] }
      ]
    }

    allow(::Translator).to receive(:translate).and_return([
      'Oi tudo bem.'
    ])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')
    expect(mash.segments.size).to eq(1)
    expect(mash.segments[0].text).to eq('Oi tudo bem.')
    expect(mash.segments[0].start).to eq(0.0)
    expect(mash.segments[0].end).to eq(1.6)
  end

  it 'keeps trailing closers attached to the sentence when split into tokens' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 1.2, text: 'Hello world ! )', words: [
          word('Hello', 0.0, 0.4),
          word('world', 0.4, 0.9),
          word('!', 0.9, 1.0),
          word(')', 1.0, 1.2)
        ]}
      ]
    }

    allow(::Translator).to receive(:translate).and_return([
      'Olá mundo!)'
    ])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')
    expect(mash.segments.size).to eq(1)
    expect(mash.segments[0].text).to eq('Olá mundo!)')
  end

  it 'groups multiple segments per sentence into separate sentence segments' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 1.2, text: 'The quick brown fox', words: [
          word('The', 0.0, 0.2), word('quick', 0.2, 0.4), word('brown', 0.4, 0.7), word('fox', 0.7, 1.2)
        ]},
        { start: 1.3, end: 2.5, text: 'jumps over the lazy dog .', words: [
          word('jumps', 1.3, 1.6), word('over', 1.6, 1.8), word('the', 1.8, 2.0), word('lazy', 2.0, 2.2), word('dog', 2.2, 2.4), word('.', 2.4, 2.5)
        ]},
        { start: 4.0, end: 5.0, text: 'Meanwhile another separate sentence', words: [
          word('Meanwhile,', 4.0, 4.3), word('another', 4.3, 4.5), word('separate', 4.5, 4.8), word('sentence', 4.8, 5.0)
        ]},
        { start: 5.2, end: 6.8, text: 'continues and ends .', words: [
          word('continues', 5.2, 5.6), word('and', 5.6, 5.9), word('ends', 5.9, 6.6), word('.', 6.6, 6.8)
        ]}
      ]
    }

    allow(::Translator).to receive(:translate).and_return([
      'Primeira frase longa com muitas palavras para não mesclar.',
      'Segunda frase também longa para manter separação.'
    ])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')
    expect(mash.segments.size).to eq(2)
    expect(mash.segments.map(&:text)).to eq([
      'Primeira frase longa com muitas palavras para não mesclar.',
      'Segunda frase também longa para manter separação.'
    ])
    expect(mash.segments[0].start).to eq(0.0)
    expect(mash.segments[0].end).to eq(2.5)
    expect(mash.segments[1].start).to eq(4.0)
    expect(mash.segments[1].end).to eq(6.8)

    vtt = backend.send(:vtt_convert, mash, normalize: false, word_tags: false)
    expect(vtt).to eq(
      "WEBVTT\n\n" \
      "00:00:00.000 --> 00:00:02.500\n" \
      "Primeira frase longa com muitas palavras para não mesclar.\n\n" \
      "00:00:04.000 --> 00:00:06.800\n" \
      "Segunda frase também longa para manter separação.\n\n"
    )
  end

  it 'spans a very long sentence across three segments and keeps as one sentence' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 1.0, text: 'This is a very', words: [
          word('This', 0.0, 0.2), word('is', 0.2, 0.3), word('a', 0.3, 0.35), word('very', 0.35, 1.0)
        ]},
        { start: 1.1, end: 2.2, text: 'long sentence that goes', words: [
          word('long', 1.1, 1.5), word('sentence', 1.5, 1.9), word('that', 1.9, 2.05), word('goes', 2.05, 2.2)
        ]},
        { start: 2.3, end: 3.3, text: 'across segments .', words: [
          word('across', 2.3, 2.6), word('segments', 2.6, 3.1), word('.', 3.1, 3.3)
        ]}
      ]
    }

    allow(::Translator).to receive(:translate).and_return([
      'Esta é uma frase muito longa que atravessa vários segmentos.'
    ])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')
    expect(mash.segments.size).to eq(1)
    expect(mash.segments[0].text).to eq('Esta é uma frase muito longa que atravessa vários segmentos.')
    expect(mash.segments[0].start).to eq(0.0)
    expect(mash.segments[0].end).to eq(3.3)

    vtt = backend.send(:vtt_convert, mash, normalize: false, word_tags: false)
    expect(vtt).to eq(
      "WEBVTT\n\n" \
      "00:00:00.000 --> 00:00:03.300\n" \
      "Esta é uma frase muito longa que atravessa vários segmentos.\n\n"
    )
  end

  it 'keeps two very long sentences (across segments) separate due to length' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 0.8, text: 'First part of a', words: [
          word('First', 0.0, 0.2), word('part', 0.2, 0.4), word('of', 0.4, 0.6), word('a', 0.6, 0.8)
        ]},
        { start: 0.9, end: 1.8, text: 'very long sentence that should not be merged', words: [
          word('very', 0.9, 1.1), word('long', 1.1, 1.3), word('sentence', 1.3, 1.5), word('that', 1.5, 1.6), word('should', 1.6, 1.7), word('not', 1.7, 1.75), word('be', 1.75, 1.78), word('merged', 1.78, 1.8)
        ]},
        { start: 1.9, end: 2.3, text: 'easily .', words: [
          word('easily', 1.9, 2.2), word('.', 2.2, 2.3)
        ]},
        { start: 2.5, end: 3.6, text: 'Second sentence that is also intentionally long', words: [
          word('Second', 2.5, 2.8), word('sentence', 2.8, 3.0), word('that', 3.0, 3.2), word('is', 3.2, 3.3), word('also', 3.3, 3.35), word('intentionally', 3.35, 3.5), word('long', 3.5, 3.6)
        ]},
        { start: 3.7, end: 4.1, text: 'to avoid merging .', words: [
          word('to', 3.7, 3.8), word('avoid', 3.8, 3.95), word('merging', 3.95, 4.05), word('.', 4.05, 4.1)
        ]}
      ]
    }

    long1 = 'Primeira frase muito extensa com muitas palavras para ultrapassar qualquer limite de compactação e evitar mescla.'
    long2 = 'Segunda sentença igualmente extensa e detalhada, composta para permanecer separada por exceder o comprimento máximo.'
    allow(::Translator).to receive(:translate).and_return([long1, long2])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')
    expect(mash.segments.size).to eq(4)
    expect((mash.segments[0].text + ' ' + mash.segments[1].text).strip).to eq(long1)
    expect((mash.segments[2].text + ' ' + mash.segments[3].text).strip).to eq(long2)
    expect(mash.segments[0].start).to eq(0.0)
    expect(mash.segments[1].end).to eq(2.3)
    expect(mash.segments[2].start).to eq(2.5)
    expect(mash.segments[3].end).to eq(4.1)

    vtt = backend.send(:vtt_convert, mash, normalize: false, word_tags: false)
    expect(vtt).to include('Primeira frase muito extensa')
    expect(vtt).to include('evitar mescla.')
    expect(vtt).to include('Segunda sentença igualmente extensa')
    expect(vtt).to include('comprimento máximo.')
  end

  it 'preserves per-word start/end timings after fuzzy token mapping' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 0.8, text: 'Hello world', words: [
          word('Hello', 0.0, 0.4), word('world', 0.4, 0.8)
        ]},
        { start: 0.8, end: 0.9, text: '!)', words: [
          word('!', 0.8, 0.85), word(')', 0.85, 0.9)
        ]},
        { start: 2.1, end: 2.9, text: 'This is fine .', words: [
          word('This', 2.1, 2.3), word('is', 2.3, 2.5), word('fine', 2.5, 2.8), word('.', 2.8, 2.9)
        ]}
      ]
    }

    # Build expected timing slots using the same sentence builder (cast to SymMash)
    sm_segments = verbose_json[:segments].map { |s| SymMash.new(s).tap { |m| m.words = Array(m.words).map { |w| SymMash.new(w) } } }
    expected_sentences = TextHelpers.sentences_from_segments(sm_segments)
    expected_timings = expected_sentences.map { |s| s.words.map { |w| [w.start, w.end] } }

    allow(::Translator).to receive(:translate).and_return([
      'Olá mundo incrível!)', # more tokens than slots
      'Ok.'                   # fewer tokens than slots
    ])

    mash = described_class.translate(verbose_json, from: 'en', to: 'pt')

    # Check counts and timing preservation per sentence
    expect(mash.segments.size).to eq(expected_sentences.size)

    mash.segments.each_with_index do |seg, i|
      got = seg.words.map { |w| [w.start, w.end] }
      # When translation has fewer tokens, some source slots are dropped; compare prefix
      expect(got).to eq(expected_timings[i].first(got.size))
    end
  end
end


