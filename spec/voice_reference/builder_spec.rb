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
      transcriber = double(call: transcript)
      selector    = double(select: candidate)
      analyzer    = double
      allow(analyzer).to receive(:extract) { |_candidate, path| File.write(path, 'wav') }

      result = described_class.new(
        transcriber: transcriber, selector: selector, analyzer: analyzer
      ).build(audio_files: ['source.webm'], output: output)

      expect(result).to eq(candidate)
      expect(selector).to have_received(:select).with([{audio: 'source.webm', transcript: transcript}])
      expect(File.read(File.join(dir, 'reference.txt'))).to eq("A complete reference sentence.\n")
      expect(JSON.parse(File.read(File.join(dir, 'reference.json')))).to include(
        'audio' => 'source.webm', 'duration' => 12.0
      )
    end
  end
end
