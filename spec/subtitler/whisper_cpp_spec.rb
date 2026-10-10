require 'rails_helper'

RSpec.describe Subtitler::WhisperCpp do
  subject(:backend) do
    Class.new do
      extend Subtitler::WhisperCpp
    end
  end

  around do |example|
    previous_api = described_class.api
    backend.api = URI.parse('http://whisper.test:8080')
    example.run
  ensure
    described_class.api = previous_api
  end

  before do
    allow(Zipper::AudioOps).to receive(:with_wav).with('audio.wav').and_yield('/tmp/audio.wav')
  end

  def words(texts, start:, finish:)
    duration = (finish - start).to_f / texts.size
    texts.map.with_index do |text, index|
      {
        word:  text,
        start: start + duration * index,
        end:   index == texts.size - 1 ? finish : start + duration * (index + 1),
      }
    end
  end

  def segment(text, start:, finish:, words:)
    {start: start, end: finish, text: text, words: words}
  end

  it 'loads verbose JSON into a normalized subtitle' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'Portuguese',
      text: ' Olá mundo',
      segments: [
        {
          start: 0.25,
          end: 1.5,
          text: ' Olá mundo',
          words: [
            { word: ' Olá', start: 0.25, end: 0.7 },
            { word: ' mundo', start: 0.8, end: 1.5 },
          ],
        },
      ],
    ))
    expect(Utils::HTTP).to receive(:post).with(
      'http://whisper.test:8080/inference',
      {
        file: '/tmp/audio.wav', temperature: '0.0',
        response_format: 'verbose_json', language: 'auto',
      }
    ).and_return(response)

    result = backend.transcribe('audio.wav')

    expect(result).to have_attributes(language: 'pt', text: 'Olá mundo')
    expect(result).to be_a(Subtitler::Subtitle)
    expect(result.entries.first.words.map { |word| [word.text, word.start, word.finish] }).to eq([
      [' Olá', 0.25, 0.7],
      [' mundo', 0.8, 1.5],
    ])
  end

  it 'merges split tokens within a segment and extends the first token timing' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'pt',
      segments: [
        {
          start: 0.0,
          end: 2.0,
          text: ' testando. outra',
          words: [
            { word: ' test', start: 0.0, end: 0.4 },
            { word: 'ando', start: 0.4, end: 0.9 },
            { word: '.', start: 0.9, end: 1.0 },
            { word: 'Outra', start: 1.1, end: 1.5 },
          ],
        },
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    segment = backend.transcribe('audio.wav').entries.first

    expect(segment.words.map { |word| [word.text, word.start, word.finish] }).to eq([
      [' testando.', 0.0, 1.0],
      ['Outra', 1.1, 1.5],
    ])
    expect(segment.text).to eq('testando. Outra')
  end

  it 'merges a leading split token across segments and removes the emptied following segment' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'pt',
      segments: [
        {
          start: 0.0,
          end: 0.5,
          text: ' test',
          words: [{ word: ' test', start: 0.0, end: 0.5 }],
        },
        {
          start: 0.5,
          end: 1.0,
          text: 'ando',
          words: [{ word: 'ando', start: 0.5, end: 1.0 }],
        },
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    segments = backend.transcribe('audio.wav').entries

    expect(segments.first.words.map { |word| [word.text, word.start, word.finish] }).to eq([
      [' testando', 0.0, 1.0],
    ])
    expect(segments.first.text).to eq('testando')
    expect(segments.first.finish).to eq(1.0)
    expect(segments.size).to eq(1)
  end

  it 'does not merge a cross-segment token after sentence punctuation' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'en',
      segments: [
        {
          start: 0.0,
          end: 0.5,
          text: ' Done!',
          words: [{ word: ' Done!', start: 0.0, end: 0.5 }],
        },
        {
          start: 0.6,
          end: 1.0,
          text: 'Next',
          words: [{ word: 'Next', start: 0.6, end: 1.0 }],
        },
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    segments = backend.transcribe('audio.wav').entries

    expect(segments.map { |segment| segment.words.map(&:text) }).to eq([[' Done!'], ['Next']])
    expect(segments.map(&:text)).to eq(['Done!', 'Next'])
  end

  it 'preserves split tokens and original segment text when merging is disabled' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'pt',
      segments: [
        {
          start: 0.0,
          end: 1.0,
          text: ' original text',
          words: [
            { word: ' test', start: 0.0, end: 0.5 },
            { word: 'ando', start: 0.5, end: 1.0 },
          ],
        },
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    segment = backend.transcribe('audio.wav', merge_words: false).entries.first

    expect(segment.words.map { |word| [word.text, word.start, word.finish] }).to eq([
      [' test', 0.0, 0.5],
      ['ando', 0.5, 1.0],
    ])
    expect(segment.text).to eq(' original text')
  end

  it 'repairs collapsed extreme-rate sentences from the reliable document speech rate' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'en', duration: 8.0,
      segments: [
        segment(' One two three four.', start: 0.0, finish: 2.0,
          words: words([' One', ' two', ' three', ' four.'], start: 0.0, finish: 2.0)),
        segment(' Broken timing needs repair.', start: 3.0, finish: 5.0, words: [
          {word: ' Broken', start: 4.0, end: 4.01},
          {word: ' timing', start: 4.0, end: 4.01},
          {word: ' needs', start: 4.0, end: 4.01},
          {word: ' repair.', start: 4.0, end: 4.01},
        ]),
        segment(' Five six seven eight.', start: 6.0, finish: 8.0,
          words: words([' Five', ' six', ' seven', ' eight.'], start: 6.0, finish: 8.0)),
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    result   = backend.transcribe('audio.wav')
    repaired = result.sentence_entries.fetch(1)

    expect(repaired.text).to eq('Broken timing needs repair.')
    expect(repaired.start).to be_within(0.0001).of(3.005)
    expect(repaired.finish).to be_within(0.0001).of(5.005)
    expect(repaired.words).to all(satisfy { |word| word.finish > word.start })
    expect(repaired.words.each_cons(2)).to all(satisfy { |left, right| left.finish == right.start })
    expect(repaired.words.first.start).to eq(repaired.start)
    expect(repaired.words.last.finish).to eq(repaired.finish)
    expect(repaired.source_words.map { |word| [word.start, word.finish] })
      .to eq(repaired.words.map { |word| [word.start, word.finish] })
  end

  it 'caps a repaired sentence to its neighboring reliable slot' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'en', duration: 5.0,
      segments: [
        segment(' One two three four.', start: 0.0, finish: 2.0,
          words: words([' One', ' two', ' three', ' four.'], start: 0.0, finish: 2.0)),
        segment(' Broken timing needs repair.', start: 2.0, finish: 3.0, words: [
          {word: ' Broken', start: 2.49, end: 2.5},
          {word: ' timing', start: 2.49, end: 2.5},
          {word: ' needs', start: 2.49, end: 2.5},
          {word: ' repair.', start: 2.49, end: 2.5},
        ]),
        segment(' Five six seven eight.', start: 3.0, finish: 5.0,
          words: words([' Five', ' six', ' seven', ' eight.'], start: 3.0, finish: 5.0)),
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    repaired = backend.transcribe('audio.wav').sentence_entries.fetch(1)

    expect(repaired).to have_attributes(start: 2.0, finish: 3.0)
  end

  it 'allocates adjacent collapsed sentences as one centered non-overlapping run' do
    collapsed = lambda do |texts, at|
      texts.map { |text| {word: text, start: at, end: at + 0.01} }
    end
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'en', duration: 10.0,
      segments: [
        segment(' One two three four.', start: 0.0, finish: 2.0,
          words: words([' One', ' two', ' three', ' four.'], start: 0.0, finish: 2.0)),
        segment(' First broken sentence here.', start: 3.0, finish: 5.0,
          words: collapsed.call([' First', ' broken', ' sentence', ' here.'], 4.0)),
        segment(' Second broken sentence here.', start: 5.0, finish: 7.0,
          words: collapsed.call([' Second', ' broken', ' sentence', ' here.'], 6.0)),
        segment(' Five six seven eight.', start: 8.0, finish: 10.0,
          words: words([' Five', ' six', ' seven', ' eight.'], start: 8.0, finish: 10.0)),
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    entries = backend.transcribe('audio.wav').sentence_entries

    expect(entries[1].start).to be_within(0.0001).of(3.005)
    expect(entries[1].finish).to be_within(0.0001).of(5.005)
    expect(entries[2].start).to be_within(0.0001).of(5.005)
    expect(entries[2].finish).to be_within(0.0001).of(7.005)
    expect(entries[1].finish).to eq(entries[2].start)
  end

  it 'leaves fast sentences unchanged when their word timings are not collapsed' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'en', duration: 4.0,
      segments: [
        segment(' One two three four.', start: 0.0, finish: 2.0,
          words: words([' One', ' two', ' three', ' four.'], start: 0.0, finish: 2.0)),
        segment(' Naturally spoken very quickly.', start: 3.0, finish: 3.5,
          words: words([' Naturally', ' spoken', ' very', ' quickly.'], start: 3.0, finish: 3.5)),
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    result = backend.transcribe('audio.wav').sentence_entries

    expect(result.last).to have_attributes(start: 3.0, finish: 3.5)
    expect(result.last.words.map { |word| [word.start, word.finish] }).to eq([
      [3.0, 3.125], [3.125, 3.25], [3.25, 3.375], [3.375, 3.5],
    ])
  end

  it 'estimates collapsed timing from the reliable speech rate of its speaker' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'en', duration: 12.0,
      segments: [
        segment(' Slow one.', start: 0.0, finish: 2.0,
          words: words([' Slow', ' one.'], start: 0.0, finish: 2.0)),
        segment(' Slow two.', start: 2.0, finish: 4.0,
          words: words([' Slow', ' two.'], start: 2.0, finish: 4.0)),
        segment(' Fast one.', start: 4.0, finish: 4.5,
          words: words([' Fast', ' one.'], start: 4.0, finish: 4.5)),
        segment(' Fast two.', start: 4.5, finish: 5.0,
          words: words([' Fast', ' two.'], start: 4.5, finish: 5.0)),
        segment(' Broken timing needs repair.', start: 6.0, finish: 8.0, words: [
          {word: ' Broken', start: 7.0, end: 7.01},
          {word: ' timing', start: 7.0, end: 7.01},
          {word: ' needs', start: 7.0, end: 7.01},
          {word: ' repair.', start: 7.0, end: 7.01},
        ]),
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)
    result = backend.transcribe('audio.wav')
    result.entries[0].assign_speaker!(0)
    result.entries[1].assign_speaker!(0)
    result.entries[2].assign_speaker!(1)
    result.entries[3].assign_speaker!(1)
    result.entries[4].assign_speaker!(0)

    repaired = result.sentence_entries.last

    expect(repaired.finish - repaired.start).to be_within(0.0001).of(4.0)
  end

  it 'falls back to the document rate when a speaker lacks reliable parts' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'en', duration: 10.0,
      segments: [
        segment(' Slow one.', start: 0.0, finish: 2.0,
          words: words([' Slow', ' one.'], start: 0.0, finish: 2.0)),
        segment(' Fast one.', start: 2.0, finish: 2.5,
          words: words([' Fast', ' one.'], start: 2.0, finish: 2.5)),
        segment(' Fast two.', start: 2.5, finish: 3.0,
          words: words([' Fast', ' two.'], start: 2.5, finish: 3.0)),
        segment(' Broken timing needs repair.', start: 5.0, finish: 7.0, words: [
          {word: ' Broken', start: 6.0, end: 6.01},
          {word: ' timing', start: 6.0, end: 6.01},
          {word: ' needs', start: 6.0, end: 6.01},
          {word: ' repair.', start: 6.0, end: 6.01},
        ]),
      ],
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)
    result = backend.transcribe('audio.wav')
    result.entries[0].assign_speaker!(0)
    result.entries[1].assign_speaker!(1)
    result.entries[2].assign_speaker!(1)
    result.entries[3].assign_speaker!(0)

    repaired = result.sentence_entries.last

    expect(repaired.finish - repaired.start).to be_within(0.0001).of(2.0)
  end

  it 'returns a model that renders SRT and VTT directly' do
    verbose = {
      'segments' => [
        {
          'start' => 0.0, 'end' => 2.0, 'text' => ' One two',
          'words' => [
            {'word' => ' One', 'start' => 0.0, 'end' => 1.0},
            {'word' => ' two', 'start' => 1.0, 'end' => 2.0},
          ],
        },
      ],
    }

    subtitle = Subtitler::Subtitle.from_whisper_verbose_json(verbose)

    expect(subtitle.to_srt).to eq(
      "1\n00:00:00,000 --> 00:00:02,000\nOne <00:00:01,000>two\n\n"
    )
    expect(subtitle.to_vtt).to eq(
      "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nOne <00:00:01.000>two\n\n"
    )
  end

end
