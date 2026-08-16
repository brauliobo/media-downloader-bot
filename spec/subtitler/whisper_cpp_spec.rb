require 'spec_helper'

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
    allow(Zipper).to receive(:with_audio_wav).with('audio.wav').and_yield('/tmp/audio.wav')
  end

  it 'loads verbose JSON into the normalized result envelope' do
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

    expect(result.lang).to eq('pt')
    expect(result.output).to be_a(SymMash)
    expect(result.output.segments.first.words.map(&:to_h)).to eq([
      { word: ' Olá', start: 0.25, end: 0.7 },
      { word: ' mundo', start: 0.8, end: 1.5 },
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

    segment = backend.transcribe('audio.wav').output.segments.first

    expect(segment.words.map(&:to_h)).to eq([
      { word: ' testando.', start: 0.0, end: 1.0 },
      { word: 'Outra', start: 1.1, end: 1.5 },
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

    segments = backend.transcribe('audio.wav').output.segments

    expect(segments.first.words.map(&:to_h)).to eq([
      { word: ' testando', start: 0.0, end: 1.0 },
    ])
    expect(segments.first.text).to eq('testando')
    expect(segments.first.end).to eq(1.0)
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

    segments = backend.transcribe('audio.wav').output.segments

    expect(segments.map { |segment| segment.words.map(&:word) }).to eq([[' Done!'], ['Next']])
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

    segment = backend.transcribe('audio.wav', merge_words: false).output.segments.first

    expect(segment.words.map(&:to_h)).to eq([
      { word: ' test', start: 0.0, end: 0.5 },
      { word: 'ando', start: 0.5, end: 1.0 },
    ])
    expect(segment.text).to eq(' original text')
  end
end
