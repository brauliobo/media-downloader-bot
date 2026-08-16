require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::Transcriber do
  it 'normalizes Whisper API output for selection' do
    backend = double
    allow(backend).to receive(:transcribe).and_return(
      Subtitler::Subtitle.from_whisper_verbose_json(
        'language' => 'en',
        'segments' => [{
          'start' => 2.5,
          'end'   => 14.5,
          'text'  => 'A clear spoken English sentence for the reusable reference voice selector.',
          'words' => [{'word' => 'clear', 'start' => 2.5, 'end' => 3.0, 'probability' => 0.96}]
        }]
      )
    )

    transcript = described_class.new(backend: backend).call('/tmp/source.wav')

    expect(backend).to have_received(:transcribe).with(
      '/tmp/source.wav', format: 'verbose_json', merge_words: false
    )
    expect(transcript[:language]).to eq('en')
    expect(transcript[:segments].first).to include(
      start: 2.5, finish: 14.5, probabilities: [0.96]
    )
  end

  it 'uses the producer-normalized subtitle language' do
    backend = double(transcribe: Subtitler::Subtitle.new(language: 'pt'))

    expect(described_class.new(backend: backend).call('/tmp/source.wav')[:language]).to eq('pt')
  end

  it 'caches prepared vocals by original source identity without nested separation' do
    Dir.mktmpdir('voice-reference-transcriber-') do |dir|
      source      = '/recordings/session/source.webm'
      backend     = double(transcribe: Subtitler::Subtitle.new(language: 'en'))
      transcriber = described_class.new(backend: backend, cache_dir: dir)

      first  = transcriber.call('/tmp/first/vocals.wav', cache_key: source, separate_voice: false)
      second = transcriber.call('/tmp/second/vocals.wav', cache_key: source, separate_voice: false)

      expect(second).to eq(first)
      expect(backend).to have_received(:transcribe).once.with(
        '/tmp/first/vocals.wav', format: 'verbose_json', merge_words: false, separate_voice: false
      )
      expect(Dir.children(dir)).to eq(["#{Digest::SHA256.hexdigest(source)}.json"])
    end
  end

  it 'rejects legacy transcription envelopes' do
    backend = double(transcribe: SymMash.new(lang: 'en', output: {segments: []}))

    expect { described_class.new(backend: backend).call('/tmp/source.wav') }
      .to raise_error(TypeError, 'transcription must be a Subtitler::Subtitle')
  end
end
