require 'spec_helper'

RSpec.describe Subtitler::Subtitle, 'translation' do
  def word(text, s, e)
    { word: text, start: s, end: e }
  end

  def subtitle(data)
    json_data = JSON.parse(JSON.generate(data))
    Subtitler::Subtitle.from_whisper_verbose_json(json_data)
  end

  def translate(subtitle, **options)
    subtitle.translated(**options)
  end

  def sentences_for(subtitle)
    subtitle.sentence_entries
  end

  it 'accepts only typed subtitles and leaves the source graph unchanged' do
    source = subtitle(
      language: 'en', text: 'Hello.',
      segments: [{start: 0, end: 1, text: 'Hello.', words: [word('Hello.', 0, 1)]}]
    )
    allow(::Translator).to receive(:translate).and_return(['Olá.'])

    translated = translate(source, from: 'en', to: 'pt')

    expect(source).to have_attributes(language: 'en', text: 'Hello.')
    expect(source.entries.first.words.map(&:text)).to eq(['Hello.'])
    expect(translated).to have_attributes(language: 'pt', text: 'Olá.')
    expect(translated.entries.first).to have_attributes(source_text: 'Hello.')
    expect(translated.entries.first.source_words.map(&:text)).to eq(['Hello.'])
    expect { described_class.new(entries: [{}]) }
      .to raise_error(TypeError, /Subtitle::Entry/)
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

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')

    expect(mash.entries.size).to eq(2)
    expect(mash.entries[0].text).to eq('Olá mundo!')
    expect(mash.entries[1].text).to eq('Isto é um teste.')

    w0 = mash.entries[0].words
    expect(w0.map(&:text)).to eq(['Olá', 'mundo!'])
    expect(w0.first.start).to eq(0.0)
    expect(w0.last.finish).to eq(0.8)
    expect(mash.entries[0].start).to eq(0.0)
    expect(mash.entries[0].finish).to eq(0.9)

    w1 = mash.entries[1].words
    expect(w1.map(&:text).join(' ')).to eq('Isto é um teste.')
    expect(mash.entries[1].start).to eq(2.5)
    expect(mash.entries[1].finish).to eq(3.5)

    vtt = mash.to_vtt(word_tags: false)
    expect(vtt).to eq(
      "WEBVTT\n\n" \
      "00:00:00.000 --> 00:00:00.900\n" \
      "Olá mundo!\n\n" \
      "00:00:02.500 --> 00:00:03.500\n" \
      "Isto é um teste.\n\n"
    )
  end

  it 'subdivides source slots when translation has more tokens' do
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

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')
    expect(mash.entries.size).to eq(1)
    expect(mash.entries[0].text).to eq('Nova Iorque, Estados Unidos.')
    words = mash.entries[0].words
    expect(words.map(&:text)).to eq(['Nova', 'Iorque,', 'Estados', 'Unidos.'])
    expect(words.map { |w| [w.start, w.finish] }).to eq([
      [0.0, 0.2], [0.2, 0.4], [0.4, 0.9], [0.9, 1.2]
    ])
  end

  it 'groups consecutive source slots when translation has fewer tokens' do
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

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')
    words = mash.entries[0].words
    expect(mash.entries[0].text).to eq('É bom.')
    expect(words.map(&:text)).to eq(['É', 'bom.'])
    expect(words.map { |w| [w.start, w.finish] }).to eq([[0.0, 0.6], [0.6, 1.5]])
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

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')
    expect(mash.entries.size).to eq(2)
    expect(mash.entries.map(&:text)).to eq(['Olá.', 'Tchau.'])
    expect(mash.entries.all? { |entry| entry.words.empty? }).to eq(true)
  end

  it 'processes contiguous timed and text-only runs without crossing representation boundaries' do
    segments = [
      SymMash.new(start: 0.0, end: 1.0, text: 'Timed start', words: [SymMash.new(word('Timed', 0.0, 0.5)), SymMash.new(word('start', 0.5, 1.0))]),
      SymMash.new(start: 1.0, end: 2.0, text: 'continues.', words: [SymMash.new(word('continues.', 1.0, 2.0))]),
      SymMash.new(start: 2.0, end: 3.0, text: 'Text only continues', words: nil),
      SymMash.new(start: 3.0, end: 4.0, text: 'without punctuation', words: []),
      SymMash.new(start: 4.0, end: 5.0, text: 'Timed again.', words: [SymMash.new(word('Timed', 4.0, 4.5)), SymMash.new(word('again.', 4.5, 5.0))]),
    ]

    sentences = sentences_for(subtitle(segments: segments))

    expect(sentences.map(&:text)).to eq(['Timed start continues.', 'Text only continues', 'without punctuation', 'Timed again.'])
    expect(sentences.map { |sentence| Array(sentence.words).any? }).to eq([true, false, false, true])
  end

  it 'keeps timed runs separate at cue and speaker boundaries and retains metadata' do
    segments = [
      SymMash.new(start: 0.0, end: 1.0, text: 'First', cue_id: 1, speaker_id: 'A', words: [SymMash.new(word('First', 0.0, 1.0))]),
      SymMash.new(start: 1.0, end: 2.0, text: 'cue', cue_id: 2, speaker_id: 'A', words: [SymMash.new(word('cue', 1.0, 2.0))]),
      SymMash.new(start: 2.0, end: 3.0, text: 'Speaker', cue_id: 2, speaker_id: 'B', words: [SymMash.new(word('Speaker', 2.0, 3.0))]),
    ]
    original_words = segments.map { |segment| segment.words.map(&:to_h) }

    sentences = sentences_for(subtitle(segments: segments))

    expect(sentences.map(&:text)).to eq(['First', 'cue', 'Speaker'])
    expect(sentences.map(&:cue_id)).to eq([1, 2, 2])
    expect(sentences.map(&:speaker_id)).to eq(['A', 'A', 'B'])
    expect(segments.map { |segment| segment.words.map(&:to_h) }).to eq(original_words)
  end

  it 'ignores transcription segments with no positive timing interval' do
    segments = [
      SymMash.new(start: 0.0, end: 1.0, words: [SymMash.new(word: 'Hello.', start: 0.0, end: 1.0)]),
      SymMash.new(start: 1.0, end: 1.0, words: [SymMash.new(word: 'Bad.', start: 1.0, end: 1.0)]),
      SymMash.new(start: 1.0, end: 2.0, words: [SymMash.new(word: 'Goodbye.', start: 1.0, end: 2.0)]),
    ]

    sentences = sentences_for(subtitle(segments: segments))

    expect(sentences.map(&:text)).to eq(['Hello.', 'Goodbye.'])
    expect(sentences).to all(satisfy { |sentence| sentence.finish > sentence.start })
  end

  it 'splits wordless text into timed sentences before translating' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 4.0, text: 'Hello. This is a second sentence.', words: nil },
      ]
    }

    allow(::Translator).to receive(:translate).and_return(['Olá.', 'Esta é uma segunda frase.'])

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')

    expect(::Translator).to have_received(:translate).with(['Hello.', 'This is a second sentence.'], from: 'en', to: 'pt')
    expect(mash.entries.map(&:text)).to eq(['Olá. Esta é uma segunda frase.'])
    expect([mash.entries.first.start, mash.entries.last.finish]).to eq([0.0, 4.0])
  end

  it 'removes a model translation label without removing legitimate dialogue' do
    verbose_json = {
      segments: [
        { start: 0.0, end: 1.0, text: 'Hello.', words: nil },
        { start: 2.2, end: 3.0, text: 'Sure.', words: nil },
      ]
    }

    allow(::Translator).to receive(:translate).and_return(['Translation: Olá.', 'Claro.'])

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')

    expect(mash.entries.map(&:text)).to eq(['Olá.', 'Claro.'])
  end

  it 'keeps honorifics together when splitting wordless text into sentences' do
    segments = [SymMash.new(start: 0.0, end: 2.0, text: 'You must be Mr. Wang. Welcome.', words: nil)]

    expect(sentences_for(subtitle(segments: segments)).map(&:text)).to eq([
      'You must be Mr. Wang.',
      'Welcome.',
    ])
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

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')
    expect(mash.entries.size).to eq(1)
    expect(mash.entries[0].text).to eq('Oi tudo bem.')
    expect(mash.entries[0].start).to eq(0.0)
    expect(mash.entries[0].finish).to eq(1.6)
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

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')
    expect(mash.entries.size).to eq(1)
    expect(mash.entries[0].text).to eq('Olá mundo!)')
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

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')
    expect(mash.entries.size).to eq(2)
    expect(mash.entries.map(&:text)).to eq([
      'Primeira frase longa com muitas palavras para não mesclar.',
      'Segunda frase também longa para manter separação.'
    ])
    expect(mash.entries[0].start).to eq(0.0)
    expect(mash.entries[0].finish).to eq(2.5)
    expect(mash.entries[1].start).to eq(4.0)
    expect(mash.entries[1].finish).to eq(6.8)

    vtt = mash.to_vtt(word_tags: false)
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

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')
    expect(mash.entries.size).to eq(1)
    expect(mash.entries[0].text).to eq('Esta é uma frase muito longa que atravessa vários segmentos.')
    expect(mash.entries[0].start).to eq(0.0)
    expect(mash.entries[0].finish).to eq(3.3)

    vtt = mash.to_vtt(word_tags: false)
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

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')
    expect(mash.entries.size).to eq(4)
    expect((mash.entries[0].text + ' ' + mash.entries[1].text).strip).to eq(long1)
    expect((mash.entries[2].text + ' ' + mash.entries[3].text).strip).to eq(long2)
    expect(mash.entries[0].start).to eq(0.0)
    expect(mash.entries[1].finish).to eq(2.3)
    expect(mash.entries[2].start).to eq(2.5)
    expect(mash.entries[3].finish).to eq(4.1)

    vtt = mash.to_vtt(word_tags: false)
    expect(vtt).to include('Primeira frase muito extensa')
    expect(vtt).to include('evitar mescla.')
    expect(vtt).to include('Segunda sentença igualmente extensa')
    expect(vtt).to include('comprimento máximo.')
  end

  it 'preserves the complete source interval after token projection' do
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

    allow(::Translator).to receive(:translate).and_return([
      'Olá mundo incrível!)', # more tokens than slots
      'Ok.'                   # fewer tokens than slots
    ])

    mash = translate(subtitle(verbose_json), from: 'en', to: 'pt')

    expect(mash.entries.size).to eq(2)
    expect(mash.entries.map { |entry| entry.words.map(&:text) })
      .to eq([['Olá', 'mundo', 'incrível!)'], ['Ok.']])
    expect(mash.entries.map { |entry| [entry.words.first.start, entry.words.last.finish] })
      .to eq([[0.0, 0.9], [2.1, 2.9]])
  end

  it 'projects lexical tokens only onto positive-duration source slots' do
    sentence = subtitle(segments: [{start: 0.0, end: 2.0, words: [
      SymMash.new(word('zero', 0.0, 0.0)),
      SymMash.new(word('first', 0.0, 1.0)),
      SymMash.new(word('zero', 1.0, 1.0)),
      SymMash.new(word('last', 1.0, 2.0)),
    ]}]).entries.first

    sentence.project_tokens!(['um', 'dois', 'três'])

    expect(sentence.words.map(&:text)).to eq(['um', 'dois', 'três'])
    expect(sentence.words.map { |word| [word.start, word.finish] }).to eq([
      [0.0, 0.5], [0.5, 1.0], [1.0, 2.0]
    ])
    expect(sentence.words).to all(satisfy { |word| word.finish > word.start })
    rendered = Subtitler::Subtitle.new(entries: [sentence]).to_vtt
    expect(rendered.scan(/<[^>]+>/)).to eq(['<00:00:00.500>', '<00:00:01.000>'])
    expect(rendered).not_to include('<00:00:02.000>')

    wordless = subtitle(segments: [{start: 1.0, end: 1.0, words: [word('zero', 1.0, 1.0)]}]).entries.first
    wordless.project_tokens!(['texto'])
    expect(wordless.words).to eq([])
  end

  it 'keeps honorific abbreviations attached to the following name' do
    segments = [
      SymMash.new(start: 0.0, end: 1.8, words: [
        SymMash.new(word('You', 0.0, 0.2)),
        SymMash.new(word('must', 0.2, 0.4)),
        SymMash.new(word('be', 0.4, 0.5)),
        SymMash.new(word('Mr.', 0.5, 0.7)),
        SymMash.new(word('Wang.', 0.7, 1.0)),
        SymMash.new(word('Welcome.', 1.2, 1.8)),
      ])
    ]

    sentences = sentences_for(subtitle(segments: segments))

    expect(sentences.map(&:text)).to eq(['You must be Mr. Wang.', 'Welcome.'])
    expect(sentences.first.finish).to eq(1.0)
  end
end
