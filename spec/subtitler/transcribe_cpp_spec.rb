require 'spec_helper'

RSpec.describe Subtitler::TranscribeCpp do
  subject(:backend) do
    Class.new do
      extend Subtitler::TranscribeCpp
    end
  end

  let(:raw_result) do
    {
      'language' => 'en',
      'text' => 'Hello world.',
      'segments' => [
        {
          't0_ms' => 400,
          't1_ms' => 1200,
          'text' => 'Hello world.',
          'words' => [
            { 't0_ms' => 400, 't1_ms' => 720, 'text' => 'Hello' },
            { 't0_ms' => 800, 't1_ms' => 1200, 'text' => 'world.' }
          ]
        }
      ]
    }
  end

  around do |example|
    previous_cli = described_class.cli
    previous_model = described_class.model
    backend.cli = '/tmp/transcribe-cli'
    backend.model = '/tmp/canary.gguf'
    example.run
  ensure
    described_class.cli = previous_cli
    described_class.model = previous_model
  end

  it 'normalizes transcribe.cpp millisecond word timings for subtitle renderers' do
    allow(backend).to receive(:run_cli).and_return(raw_result)

    result = backend.transcribe('audio.wav')

    expect(result.lang).to eq('en')
    expect(result.output.segments.first).to include(
      start: 0.4,
      end: 1.2,
      text: 'Hello world.'
    )
    expect(result.output.segments.first.words.map(&:to_h)).to eq([
      { word: 'Hello', start: 0.4, end: 0.72 },
      { word: 'world.', start: 0.8, end: 1.2 }
    ])
  end

  it 'reuses the existing word-tagged SRT renderer' do
    allow(backend).to receive(:run_cli).and_return(raw_result)

    output = backend.transcribe('audio.wav').output

    expect(backend.srt_convert(output, normalize: false)).to include(
      "00:00:00,400 --> 00:00:01,200\nHello <00:00:00,800>world."
    )
  end
end
