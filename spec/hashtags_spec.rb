require 'spec_helper'
require_relative '../lib/hashtags'

RSpec.describe Hashtags do
  it 'generates normalized hashtags with the requested language and rules' do
    captured = nil
    backend = double('codex')
    allow(backend).to receive(:json_prompt) do |prompt, **kwargs|
      captured = {prompt: prompt, kwargs: kwargs}
      ['Mindfulness', 'mindfulness', 'Saúde', 'two words', 'three word term']
    end

    subtitle = Subtitler::Subtitle.new(
      language: 'pt',
      entries: [Subtitler::Subtitle::Entry.new(
        text: 'A transcript about mindfulness and health.', start: 0.0, finish: 1.0
      )]
    )
    result = described_class.new(backend: backend).call(subtitle)

    expect(result).to eq('#Mindfulness #Saúde #TwoWords')
    expect(captured[:kwargs]).to include(model: 'gpt-5.6-luna', effort: 'low', schema: described_class::HASHTAG_SCHEMA)
    expect(captured[:prompt]).to include('Write every hashtag in pt.')
    expect(captured[:prompt]).to include('Ruby will format them as PascalCase hashtags')
    expect(captured[:prompt]).to include('majority of cases')
    expect(captured[:prompt]).to include('meaningful concept together')
    expect(captured[:prompt]).to include('A transcript about mindfulness and health.')
  end

  it 'does not invoke Codex for an empty transcription' do
    backend = double('codex')
    expect(backend).not_to receive(:json_prompt)

    expect(described_class.new(backend: backend).call('   ')).to eq('')
  end

  it 'rejects generic structured values' do
    expect { described_class.new(backend: double).call({text: 'Transcript'}) }
      .to raise_error(TypeError, 'transcription must be a Subtitler::Subtitle or String')
  end
end
