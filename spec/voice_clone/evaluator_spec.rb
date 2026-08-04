require 'json'
require 'spec_helper'
require_relative '../../lib/voice_clone/evaluator'

RSpec.describe VoiceClone::Evaluator do
  it 'runs baseline and reference cases and writes reusable reports' do
    Dir.mktmpdir('voice-clone-eval-') do |dir|
      synthesizer = double
      allow(synthesizer).to receive(:synthesize) do |**options|
        File.write(options.fetch(:out_path), 'wav')
      end
      transcriber = double(call: {language: 'pt', segments: [{text: 'Texto de teste.', probabilities: [0.9]}]})
      transcript_scorer = double(call: {match_rate: 1.0, word_error_rate: 0.0})
      embedding_scorer = double(call: {cosine_similarity: 0.87})

      report = described_class.new(
        output_dir: dir,
        synthesizer: synthesizer,
        transcriber: transcriber,
        transcript_scorer: transcript_scorer,
        embedding_scorer: embedding_scorer,
        clock: -> { Time.utc(2026, 1, 2, 3, 4, 5) },
        monotonic_clock: monotonic_clock
      ).run(
        text: 'Texto de teste.', language: 'pt', reference_audio: 'reference.wav',
        reference_text: 'Texto de referência.', comparison_audio: 'source.wav',
        cases: [
          VoiceClone::Case.new(name: 'baseline'),
          VoiceClone::Case.new(name: 'clone', reference: true, parameters: {guidance: 1})
        ]
      )

      expect(report[:results].size).to eq(2)
      expect(report[:results]).to all(include(success: true, speaker_similarity: {cosine_similarity: 0.87}))
      expect(synthesizer).to have_received(:synthesize).twice
      expect(synthesizer).to have_received(:synthesize).with(
        hash_including(text: 'Texto de teste.', lang: 'pt', guidance: 1, speaker_wav: File.expand_path('reference.wav'))
      )
      expect(File).to exist(File.join(dir, 'results.json'))
      expect(File).to exist(File.join(dir, 'summary.csv'))
      expect(JSON.parse(File.read(File.join(dir, 'results.json')))).to include('results', 'artifacts')
    end
  end

  def monotonic_clock
    values = [10.0, 10.25, 20.0, 20.5]
    -> { values.shift || 20.5 }
  end
end
