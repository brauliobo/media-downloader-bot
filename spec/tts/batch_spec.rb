require 'spec_helper'

RSpec.describe 'TTS batch synthesis' do
  it 'falls back to scalar synthesis when the backend has no batch API' do
    backend = Class.new do
      class << self
        attr_reader :calls

        def synthesize(**args)
          (@calls ||= []) << args
          args[:out_path]
        end
      end
    end
    stub_const('TTS::BACKEND', backend)

    result = TTS.synthesize_batch(
      items: [
        { text: 'One', out_path: 'one.wav' },
        { text: 'Two', out_path: 'two.wav' },
      ],
      lang:           'en',
      tts_batch_size: 100,
      speed:          1.1
    )

    expect(result).to eq(%w[one.wav two.wav])
    expect(backend.calls).to eq([
      { lang: 'en', speed: 1.1, text: 'One', out_path: 'one.wav' },
      { lang: 'en', speed: 1.1, text: 'Two', out_path: 'two.wav' },
    ])
  end

  it 'delegates to a backend batch API in configured chunks' do
    backend = Class.new do
      class << self
        attr_reader :batches

        def supports_batch_synthesis?
          true
        end

        def synthesize_batch(items:, **args)
          (@batches ||= []) << { items: items, args: args }
          items.map { |item| item[:out_path] }
        end
      end
    end
    stub_const('TTS::BACKEND', backend)

    result = TTS.synthesize_batch(
      items: [
        { text: 'One', out_path: 'one.wav' },
        { text: 'Two', out_path: 'two.wav' },
        { text: 'Three', out_path: 'three.wav' },
      ],
      lang:           'en',
      tts_batch_size: 2
    )

    expect(result).to eq(%w[one.wav two.wav three.wav])
    expect(backend.batches.map { |batch| batch[:items].size }).to eq([2, 1])
    expect(backend.batches.first[:args]).to eq(lang: 'en')
  end
end
