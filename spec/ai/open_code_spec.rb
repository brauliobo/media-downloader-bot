require 'spec_helper'
require_relative '../../lib/ai/open_code'

RSpec.describe AI::OpenCode do
  let(:schema) do
    AI::JSONSchema.object(text: { type: 'string' })
  end

  it 'validates JSON output against the provided schema' do
    allow(described_class).to receive(:prompt).and_return('{"text":"ok"}')

    expect(described_class.json_prompt('return json', schema: schema)).to eq('text' => 'ok')
  end

  it 'raises when OpenCode returns JSON that does not match the schema' do
    allow(described_class).to receive(:prompt).and_return('{"other":"bad"}')

    expect { described_class.json_prompt('return json', schema: schema) }
      .to raise_error(/schema validation failed/)
  end
end
