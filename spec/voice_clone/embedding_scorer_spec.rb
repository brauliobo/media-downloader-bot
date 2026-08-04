require 'json'
require 'spec_helper'
require_relative '../../lib/voice_clone/embedding_scorer'

RSpec.describe VoiceClone::EmbeddingScorer do
  it 'runs the configured embedding command and parses cosine similarity' do
    status = instance_double(Process::Status, success?: true)
    command = nil
    runner = lambda do |*args|
      command = args
      [JSON.dump(cosine_similarity: 0.87, dimension: 192), '', status]
    end
    scorer = described_class.new(
      python: 'python', script: 'embedding.py', model: 'titanet.onnx',
      provider: 'cuda', num_threads: 2, normalize_audio: false, runner: runner
    )

    result = scorer.call(reference: 'reference.wav', sample: 'sample.wav')

    expect(result).to include(cosine_similarity: 0.87, dimension: 192)
    expect(command).to eq([
      'python', 'embedding.py', '--model', 'titanet.onnx', '--provider', 'cuda', '--num-threads', '2',
      '--reference', 'reference.wav', '--sample', 'sample.wav'
    ])
  end
end
