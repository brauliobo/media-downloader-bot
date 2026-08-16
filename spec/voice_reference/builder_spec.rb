require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::Builder do
  it 'transcribes recordings and writes the selected reference with sidecars' do
    Dir.mktmpdir('voice-reference-builder-') do |dir|
      output     = File.join(dir, 'reference.wav')
      transcript = subtitle(language: 'en')
      candidate  = VoiceReference::Candidate.new(
        audio: 'source.webm', start: 12, finish: 24,
        text: 'A complete reference sentence.', confidence: 0.95,
        metrics: {peak_db: -3}, score: 1.0
      )
      transcriber = double
      allow(transcriber).to receive(:call) do |path|
        path == 'source.webm' ? transcript : subtitle(text: candidate.text, language: 'en')
      end
      selector = double(rank: [candidate])
      analyzer    = double
      statuses    = []
      allow(analyzer).to receive(:extract) { |_candidate, path| File.write(path, 'wav') }
      allow(analyzer).to receive(:report).and_return(accepted: true)

      result = described_class.new(
        transcriber: transcriber, selector: selector, analyzer: analyzer,
        on_status: ->(status) { statuses << status }
      ).build(audio_files: ['source.webm'], output: output)

      expect(result).to eq(candidate)
      expect(selector).to have_received(:rank).with([{audio: 'source.webm', transcript: transcript}])
      expect(File.read(File.join(dir, 'reference.txt'))).to eq("A complete reference sentence.\n")
      expect(JSON.parse(File.read(File.join(dir, 'reference.json')))).to include(
        'audio' => 'source.webm', 'duration' => 12.0
      )
      expect(candidate.validation).to include(accepted: true)
      expect(candidate.validation[:selection]).to eq(rank: 1, rejected_candidates: 0)
      expect(candidate.artifacts.dig(:audio, :path)).to eq(output)
      expect(candidate.artifacts.dig(:audio, :sha256)).to match(/\A[0-9a-f]{64}\z/)
      expect(statuses).to eq(['Validating voice reference 1/1'])
    end
  end

  it 'builds the best clear reference from a downloaded URL' do
    Dir.mktmpdir('voice-reference-url-') do |dir|
      output     = File.join(dir, 'reference.wav')
      source     = File.join(dir, 'source.webm')
      candidate  = VoiceReference::Candidate.new(text: 'The selected clear passage.')
      downloader = double(call: source)
      transcriber = double
      allow(VoiceReference).to receive(:from_files).and_return(candidate)

      result = VoiceReference.from_url(
        url: 'https://example.com/voice', output: output, downloader: downloader, transcriber: transcriber
      )

      expect(result).to eq(candidate)
      expect(downloader).to have_received(:call).with('https://example.com/voice', dir: dir)
      expect(VoiceReference).to have_received(:from_files).with(
        audio_files: [source], output: output, language: nil, transcriber: transcriber,
        reference_filter: :raw, on_status: nil
      )
    end
  end

  it 'reports each URL extraction stage' do
    Dir.mktmpdir('voice-reference-status-') do |dir|
      source     = File.join(dir, 'source.webm')
      output     = File.join(dir, 'reference.wav')
      transcript = subtitle(language: 'pt')
      candidate  = VoiceReference::Candidate.new(text: 'Uma passagem clara.')
      downloader = double(call: source)
      transcriber = double
      selector    = instance_double(VoiceReference::Selector)
      builder     = instance_double(described_class, build: candidate)
      statuses    = []
      on_status   = ->(status) { statuses << status }
      allow(VoiceSeparator).to receive(:separate).with(source, dir: kind_of(String)) do |_source, dir:|
        vocals     = File.join(dir, 'vocals.wav')
        non_vocals = File.join(dir, 'no-vocals.wav')
        File.write(vocals, 'voice')
        File.write(non_vocals, 'music')
        VoiceSeparator::Stems.new(vocals: vocals, non_vocals: non_vocals)
      end
      allow(transcriber).to receive(:call).with(
        kind_of(String), cache_key: source, separate_voice: false
      ).and_return(transcript)
      allow(VoiceReference::Selector).to receive(:new).and_return(selector)
      allow(described_class).to receive(:new).with(
        transcriber: transcriber, selector: selector, language: 'pt', reference_filter: :raw,
        on_status: on_status
      ).and_return(builder)

      result = VoiceReference.from_url(
        url: 'https://example.com/voice', output: output,
        downloader: downloader, transcriber: transcriber, on_status: on_status
      )

      expect(result).to eq(candidate)
      expect(statuses).to eq([
        'Downloading voice reference',
        'Transcribing voice reference',
        'Selecting voice reference',
        'Voice reference ready'
      ])
    end
  end

  it 'extracts and validates prepared vocals while reporting the original source' do
    Dir.mktmpdir('voice-reference-prepared-') do |dir|
      source      = '/recordings/source.webm'
      vocals      = File.join(dir, 'vocals.wav')
      output      = File.join(dir, 'reference.wav')
      transcript  = subtitle(language: 'en')
      candidate   = VoiceReference::Candidate.new(
        audio: vocals, start: 12, finish: 20, text: 'A complete prepared vocal reference.', confidence: 0.95
      )
      validation  = subtitle(text: candidate.text, language: 'en')
      selector    = double(rank: [candidate])
      transcriber = double
      analyzer     = double(report: {accepted: true})
      expected_key = Digest::SHA256.hexdigest([source, candidate.start, candidate.finish].join(':'))
      allow(analyzer).to receive(:extract) do |selected, path, filter:|
        expect(selected.audio).to eq(vocals)
        expect(filter).to eq(:raw)
        File.write(path, 'vocal clip')
      end
      allow(transcriber).to receive(:call).with(
        kind_of(String), cache_key: "validation:raw:#{expected_key}", separate_voice: false
      ).and_return(validation)

      result = described_class.new(
        transcriber: transcriber, selector: selector, analyzer: analyzer
      ).build(
        audio_files: [vocals], source_files: [source], output: output, transcripts: {source => transcript}
      )

      expect(selector).to have_received(:rank).with([{audio: vocals, transcript: transcript}])
      expect(result.audio).to eq(source)
      expect(JSON.parse(File.read(File.join(dir, 'reference.json'))).fetch('audio')).to eq(source)
      expect(transcriber).to have_received(:call).once
    end
  end

  it 'validates the extracted transcript in the configured language' do
    builder = described_class.new(language: 'pt')
    text    = 'Esta passagem de referência possui uma voz clara e natural.'
    report  = builder.send(
      :validation_report,
      text,
      subtitle(text: text, language: 'pt'),
      {accepted: true}
    )

    expect(report[:accepted]).to eq(true)
    expect(report[:tools]).to eq FFmpeg::TOOLS.merge(transcription: 'Subtitler::WhisperCpp')
  end

  it 'uses the configured language when transcription omits detection' do
    transcript = subtitle
    selector   = double(rank: [])
    builder    = described_class.new(transcriber: double(call: transcript), selector: selector, language: 'es')

    expect do
      builder.build(audio_files: ['source.opus'], output: 'reference.wav')
    end.to raise_error(RuntimeError, /no voice reference candidate/)

    expect(selector).to have_received(:rank).with([
      {audio: 'source.opus', transcript: satisfy { |value|
        value.is_a?(Subtitler::Subtitle) && value.language == 'es' && value.entries.empty?
      }}
    ])
    expect(transcript.language).to be_nil
  end

  it 'uses the configured language when clip validation omits detection' do
    builder = described_class.new(language: 'es')
    text    = 'Además, son capaces de disipar las cargas eléctricas.'
    report  = builder.send(
      :validation_report,
      text,
      subtitle(text: text),
      {accepted: true}
    )

    expect(report[:accepted]).to eq(true)
    expect(report.dig(:transcript, :language)).to eq('es')
  end
  def subtitle(text: nil, language: nil, probability: 0.95, metadata: {})
    entries = if text
      words = text.split.map do |word|
        Subtitler::Subtitle::Word.new(text: word, start: 0, finish: 8, confidence: probability)
      end
      [Subtitler::Subtitle::Entry.new(start: 0, finish: 8, text: text, words: words, metadata: metadata)]
    else
      []
    end
    Subtitler::Subtitle.new(language: language, text: text, entries: entries)
  end
end
