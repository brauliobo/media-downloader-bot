require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::Builder do
  it 'transcribes recordings and writes the selected reference with sidecars' do
    Dir.mktmpdir('voice-reference-builder-') do |dir|
      output     = File.join(dir, 'reference.wav')
      transcript = {language: 'en', segments: []}
      candidate  = VoiceReference::Candidate.new(
        audio: 'source.webm', start: 12, finish: 24,
        text: 'A complete reference sentence.', confidence: 0.95,
        metrics: {peak_db: -3}, score: 1.0
      )
      transcriber = double
      allow(transcriber).to receive(:call) do |path|
        path == 'source.webm' ? transcript : {
          language: 'en',
          segments: [{
            text: candidate.text,
            probabilities: Array.new(candidate.text.split.size, 0.95)
          }]
        }
      end
      selector = double(rank: [candidate])
      analyzer    = double
      allow(analyzer).to receive(:extract) { |_candidate, path| File.write(path, 'wav') }
      allow(analyzer).to receive(:report).and_return(accepted: true)

      result = described_class.new(
        transcriber: transcriber, selector: selector, analyzer: analyzer
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
    end
  end

  it 'builds the best clear reference from a downloaded URL' do
    Dir.mktmpdir('voice-reference-url-') do |dir|
      output     = File.join(dir, 'reference.wav')
      source     = File.join(dir, 'source.webm')
      candidate  = VoiceReference::Candidate.new(text: 'The selected clear passage.')
      transcript = {language: 'pt', segments: []}
      downloader = double(call: source)
      transcriber = double(call: transcript)
      selector   = instance_double(VoiceReference::Selector)
      builder    = instance_double(described_class, build: candidate)
      allow(VoiceReference::Selector).to receive(:new).with(language: 'pt', strict: true).and_return(selector)
      allow(described_class).to receive(:new).with(
        transcriber: transcriber, selector: selector, language: 'pt', reference_filter: :raw
      ).and_return(builder)

      result = VoiceReference.from_url(
        url: 'https://example.com/voice', output: output, downloader: downloader, transcriber: transcriber
      )

      expect(result).to eq(candidate)
      expect(downloader).to have_received(:call).with('https://example.com/voice', dir: dir)
      expect(transcriber).to have_received(:call).with(source)
      expect(builder).to have_received(:build).with(
        audio_files: [source], output: output, transcripts: {source => transcript}
      )
    end
  end

  it 'validates the extracted transcript in the configured language' do
    builder = described_class.new(language: 'pt')
    text    = 'Esta passagem de referência possui uma voz clara e natural.'
    report  = builder.send(
      :validation_report,
      text,
      {
        language: 'pt',
        segments: [{text: text, probabilities: Array.new(text.split.size, 0.95)}]
      },
      {accepted: true}
    )

    expect(report[:accepted]).to eq(true)
  end
end
