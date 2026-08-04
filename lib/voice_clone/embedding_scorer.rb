require 'json'
require 'open3'

require_relative '../zipper'

class VoiceClone
  class EmbeddingScorer
    DEFAULT_PYTHON = '/srv/sherpa-onnx/runtime/bin/python'
    DEFAULT_MODEL  = '/srv/sherpa-onnx/models/embedding/nemo_en_titanet_small.onnx'

    def initialize(
      python: nil,
      script: File.expand_path('../../bin/voice_clone_embedding.py', __dir__),
      model: nil,
      provider: nil,
      num_threads: nil,
      normalize_audio: true,
      runner: nil
    )
      @python          = python || ENV['VOICE_CLONE_EMBEDDING_PYTHON'] || ENV['SHERPA_ONNX_PYTHON'] || DEFAULT_PYTHON
      @script          = script
      @model           = model || ENV['VOICE_CLONE_EMBEDDING_MODEL'] || ENV['SHERPA_EMBEDDING_MODEL'] || DEFAULT_MODEL
      @provider        = provider || ENV['VOICE_CLONE_EMBEDDING_PROVIDER'] || 'cuda'
      @num_threads     = (num_threads || ENV['VOICE_CLONE_EMBEDDING_THREADS'] || 1).to_i
      @normalize_audio = normalize_audio
      @runner          = runner || Open3.method(:capture3)
    end

    def call(reference:, sample:)
      references = paths(reference)
      samples = paths(sample)
      raise ArgumentError, 'speaker embedding reference is empty' if references.empty?
      raise ArgumentError, 'speaker embedding sample is empty' if samples.empty?

      normalize(references) do |reference_paths|
        normalize(samples) do |sample_paths|
          run(reference_paths, sample_paths)
        end
      end
    end

    private

    def paths(value)
      Array(value).compact.map(&:to_s).reject(&:empty?)
    end

    def normalize(paths, &block)
      return block.call(paths) unless @normalize_audio

      normalized = []
      normalize_one(paths, normalized, &block)
    end

    def normalize_one(paths, normalized, &block)
      return block.call(normalized) if paths.empty?

      Zipper.with_audio_wav(paths.first, sample_rate: 16_000, channels: 1) do |file|
        normalized << file.path
        normalize_one(paths.drop(1), normalized, &block)
      ensure
        normalized.pop
      end
    end

    def run(references, samples)
      command = [
        @python, @script,
        '--model', @model,
        '--provider', @provider,
        '--num-threads', @num_threads.to_s,
        '--reference', *references,
        '--sample', *samples
      ]
      stdout, stderr, status = @runner.call(*command)
      raise "speaker embedding failed: #{stderr.to_s.strip}" unless status.success?

      report = JSON.parse(stdout, symbolize_names: true)
      similarity = Float(report.fetch(:cosine_similarity))
      raise 'speaker embedding returned a non-finite similarity' unless similarity.finite?

      report
    rescue JSON::ParserError => error
      raise "speaker embedding returned invalid JSON: #{error.message}"
    end
  end
end
