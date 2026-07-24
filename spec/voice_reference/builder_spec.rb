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
end
