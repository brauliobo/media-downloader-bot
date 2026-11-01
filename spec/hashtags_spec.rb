require 'rails_helper'

RSpec.describe Hashtags do
  it 'generates normalized hashtags with the requested language and rules' do
    captured = nil
    backend = double('backend')
    allow(backend).to receive(:json_prompt) do |prompt, **kwargs|
      captured = {prompt: prompt, kwargs: kwargs}
      [
        {'tag' => 'Mindfulness', 'detail' => ''}, {'tag' => 'mindfulness', 'detail' => ''}, {'tag' => 'Dose', 'detail' => '200mg duas vezes ao dia'},
        {'tag' => 'saúde', 'detail' => '  '}, {'tag' => 'BPC157', 'detail' => ''}, {'tag' => 'two words', 'detail' => ''}, {'tag' => 'three word term', 'detail' => ''}
      ]
    end

    subtitle = Subtitler::Subtitle.new(
      language: 'pt',
      entries: [Subtitler::Subtitle::Entry.new(
        text: 'A transcript about mindfulness and health.', start: 0.0, finish: 1.0
      )]
    )
    result = described_class.new(backend: backend).call(subtitle)

    expect(result).to eq('#Mindfulness #Dose 200mg duas vezes ao dia #Saúde #BPC157 #Two #Words')
    expect(captured[:kwargs]).to include(schema: described_class::HASHTAG_SCHEMA)
    expect(captured[:prompt]).to include('Write every hashtag in pt.')
    expect(captured[:prompt]).to include('Ruby will format it as a PascalCase hashtag')
    expect(captured[:prompt]).to include('Never add topics, names or facts from your own knowledge')
    expect(captured[:prompt]).to include('majority of cases')
    expect(captured[:prompt]).to include('exactly one word')
    expect(captured[:prompt]).to include('200mg twice a day')
    expect(captured[:prompt]).to include('never "gut health"')
    expect(captured[:prompt]).to include('A transcript about mindfulness and health.')
  end

  it 'does not invoke the backend for an empty transcription' do
    backend = double('backend')
    expect(backend).not_to receive(:json_prompt)

    expect(described_class.new(backend: backend).call('   ')).to eq('')
  end
end
