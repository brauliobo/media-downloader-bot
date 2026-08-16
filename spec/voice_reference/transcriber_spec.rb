require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::Transcriber do
  it 'returns the backend subtitle for selection' do
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
    expect(transcript).to be_a(Subtitler::Subtitle)
    expect(transcript.language).to eq('en')
    expect(transcript.entries.first.start).to eq(2.5)
    expect(transcript.entries.first.finish).to eq(14.5)
    expect(transcript.entries.first.words.map(&:confidence)).to eq([0.96])
  end

  it 'uses the producer-normalized subtitle language' do
    backend = double(transcribe: Subtitler::Subtitle.new(language: 'pt'))

    expect(described_class.new(backend: backend).call('/tmp/source.wav').language).to eq('pt')
  end

  it 'caches prepared vocals by original source identity without nested separation' do
    Dir.mktmpdir('voice-reference-transcriber-') do |dir|
      source      = '/recordings/session/source.webm'
      subtitle = Subtitler::Subtitle.new(
        language: 'en',
        text:     'Cached words.',
        entries:  [Subtitler::Subtitle::Entry.new(
          start: 1.0, finish: 2.0, text: 'Cached words.', metadata: {'avg_logprob' => -0.2},
          words: [Subtitler::Subtitle::Word.new(
            text: 'Cached', start: 1.0, finish: 1.5, confidence: 0.91, metadata: {'token' => 7}
          )]
        )],
        metadata: {'model' => 'test'}
      )
      backend     = double(transcribe: subtitle)
      transcriber = described_class.new(backend: backend, cache_dir: dir)

      first  = transcriber.call('/tmp/first/vocals.wav', cache_key: source, separate_voice: false)
      second = transcriber.call('/tmp/second/vocals.wav', cache_key: source, separate_voice: false)

      expect(first).to equal(subtitle)
      expect(second).to be_a(Subtitler::Subtitle)
      expect(second).not_to equal(first)
      expect(second.language).to eq('en')
      expect(second.text).to eq('Cached words.')
      expect(second.metadata).to eq('model' => 'test')
      expect(second.entries.first.metadata).to eq('avg_logprob' => -0.2)
      expect(second.entries.first.words.first.confidence).to eq(0.91)
      expect(second.entries.first.words.first.metadata).to eq('token' => 7)
      expect(backend).to have_received(:transcribe).once.with(
        '/tmp/first/vocals.wav', format: 'verbose_json', merge_words: false, separate_voice: false
      )
      cache = File.join(dir, "#{Digest::SHA256.hexdigest(source)}.json")
      expect(Dir.children(dir)).to eq([File.basename(cache)])
      expect(JSON.parse(File.read(cache))).to include(
        'version' => 1,
        'subtitle' => hash_including(
          'language' => 'en',
          'entries' => [hash_including('finish' => 2.0, 'words' => [hash_including('confidence' => 0.91)])]
        )
      )
    end
  end

  it 'rejects legacy unversioned cache files' do
    Dir.mktmpdir('voice-reference-transcriber-') do |dir|
      File.write(File.join(dir, 'source.json'), JSON.generate(language: 'en', segments: []))

      expect { described_class.new(backend: double, cache_dir: dir).call('/tmp/source.wav') }
        .to raise_error(ArgumentError, 'voice reference transcript cache is missing a version')
    end
  end

  it 'rejects unsupported cache versions' do
    Dir.mktmpdir('voice-reference-transcriber-') do |dir|
      File.write(File.join(dir, 'source.json'), JSON.generate(version: 2, subtitle: {}))

      expect { described_class.new(backend: double, cache_dir: dir).call('/tmp/source.wav') }
        .to raise_error(ArgumentError, 'unsupported voice reference transcript cache version: 2')
    end
  end

  it 'rejects legacy transcription envelopes' do
    backend = double(transcribe: SymMash.new(lang: 'en', output: {segments: []}))

    expect { described_class.new(backend: backend).call('/tmp/source.wav') }
      .to raise_error(TypeError, 'transcription must be a Subtitler::Subtitle')
  end
end
