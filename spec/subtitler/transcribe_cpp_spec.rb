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
    previous_cli    = described_class.cli
    previous_model  = described_class.model
    previous_ffmpeg = described_class.ffmpeg
    backend.cli     = '/tmp/transcribe-cli'
    backend.model   = '/tmp/canary.gguf'
    backend.ffmpeg  = '/opt/transcribe/bin/ffmpeg'
    example.run
  ensure
    described_class.cli    = previous_cli
    described_class.model  = previous_model
    described_class.ffmpeg = previous_ffmpeg
  end

  it 'preserves runtime FFmpeg binary configuration' do
    expect(backend.ffmpeg).to eq '/opt/transcribe/bin/ffmpeg'

    backend.ffmpeg = '/tmp/custom-ffmpeg'

    expect(described_class.ffmpeg).to eq '/tmp/custom-ffmpeg'
  end

  it 'normalizes transcribe.cpp millisecond word timings for subtitle renderers' do
    allow(backend).to receive(:run_cli).and_return(raw_result)

    result = backend.transcribe('audio.wav')

    expect(result).to have_attributes(language: 'en', text: 'Hello world.')
    expect(result.entries.first).to have_attributes(start: 0.4, finish: 1.2, text: 'Hello world.')
    expect(result.entries.first.words.map { |word| [word.text, word.start, word.finish] }).to eq([
      ['Hello', 0.4, 0.72],
      ['world.', 0.8, 1.2]
    ])
  end

  it 'uses segment spacing to merge transcribe.cpp split-word boundaries only when requested' do
    split_result = raw_result.merge(
      'text' => 'testing',
      'segments' => [
        {
          't0_ms' => 0,
          't1_ms' => 900,
          'text' => 'testing',
          'words' => [
            { 't0_ms' => 0, 't1_ms' => 400, 'text' => 'test' },
            { 't0_ms' => 400, 't1_ms' => 900, 'text' => 'ing' },
          ],
        },
      ]
    )
    allow(backend).to receive(:run_cli).and_return(split_result)

    merged = backend.transcribe('audio.wav', merge_words: true).entries.first
    unmerged = backend.transcribe('audio.wav', merge_words: false).entries.first

    expect(merged.words.map(&:text)).to eq(%w[testing])
    expect(unmerged.words.map(&:text)).to eq(%w[test ing])
    expect(merged.text).to eq('testing')
    expect(unmerged.text).to eq('testing')
  end

  it 'reuses the existing word-tagged SRT renderer' do
    allow(backend).to receive(:run_cli).and_return(raw_result)

    output = backend.transcribe('audio.wav')

    expect(backend.srt_convert(output, normalize: false)).to include(
      "00:00:00,400 --> 00:00:01,200\nHello <00:00:00,800>world."
    )
  end

  it 'carries rounded milliseconds into the next SRT second' do
    output = Subtitler::Subtitle.new(entries: [
      Subtitler::Subtitle::Entry.new(text: 'Carry', start: 1.9996, finish: 62.9996),
    ])

    expect(backend.srt_convert(output, normalize: false)).to include(
      '00:00:02,000 --> 00:01:03,000'
    )
  end

  it 'uses FFmpeg transcription binary for semantic WAV preprocessing' do
    converter = instance_double FFmpeg
    status = instance_double Process::Status, success?: true
    expect(FFmpeg).to receive(:new).with(ffmpeg: '/opt/transcribe/bin/ffmpeg').and_return converter
    expect(converter).to receive(:transcribe_wav) do |arguments|
      expect(arguments).to eq(
        input: 'audio.mp3', output: arguments.fetch(:output), label: 'ffmpeg failed'
      )
      expect(arguments.fetch(:output)).to end_with '.wav'
    end
    expect(Open3).to receive(:capture3) do |*command|
      result = command.fetch 11
      wav    = command.fetch 12
      expect(command).to eq [
        '/tmp/transcribe-cli', '--quiet', '--model', '/tmp/canary.gguf', '--language', 'en',
        '--timestamps', 'word', '--backend', 'auto', '--output-json', result, wav
      ]
      expect(result).to end_with '.json'
      expect(wav).to end_with '.wav'
      File.write result, JSON.generate(raw_result)
      ['', '', status]
    end

    expect(backend.transcribe('audio.mp3').text).to eq 'Hello world.'
  end

  it 'propagates FFmpeg preprocessing failures without invoking transcribe.cpp' do
    converter = instance_double FFmpeg
    failure = Sh::Error.new 'ffmpeg failed', 'invalid audio'
    allow(FFmpeg).to receive(:new).with(ffmpeg: '/opt/transcribe/bin/ffmpeg').and_return converter
    allow(converter).to receive(:transcribe_wav).and_raise failure
    expect(Open3).not_to receive :capture3

    expect { backend.transcribe 'audio.mp3' }.to raise_error failure
  end
end
