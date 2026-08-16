require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::Transcriber do
  it 'normalizes Whisper API output for selection' do
    backend = double
    allow(backend).to receive(:transcribe).and_return(SymMash.new(
      lang: 'en',
      output: {
        language: 'english',
        segments: [{
          start: 2.5,
          end: 14.5,
          text: 'A clear spoken English sentence for the reusable reference voice selector.',
          words: [{word: 'clear', probability: 0.96}]
        }]
      }
    ))

    transcript = described_class.new(backend: backend).call('/tmp/source.wav')

    expect(backend).to have_received(:transcribe).with(
      '/tmp/source.wav', format: 'verbose_json', merge_words: false
    )
    expect(transcript[:language]).to eq('en')
    expect(transcript[:segments].first).to include(
      start: 2.5, finish: 14.5, probabilities: [0.96]
    )
  end

  it 'normalizes language names, codes, and locale-qualified identifiers' do
    {
      'english' => 'en',
      'pt'      => 'pt',
      'pt-PT'   => 'pt',
      'pt-BR'   => 'pt',
      'pt_PT'   => 'pt',
      'en-US'   => 'en',
      'es_MX'   => 'es',
      'unknown' => nil,
    }.each do |language, expected|
      result = SymMash.new(lang: nil, output: {language: language, segments: []})
      backend = double(transcribe: result)

      expect(described_class.new(backend: backend).call('/tmp/source.wav')[:language]).to eq(expected)
    end
  end

  it 'caches prepared vocals by original source identity without nested separation' do
    Dir.mktmpdir('voice-reference-transcriber-') do |dir|
      source      = '/recordings/session/source.webm'
      backend     = double(transcribe: SymMash.new(lang: 'en', output: {segments: []}))
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
end
