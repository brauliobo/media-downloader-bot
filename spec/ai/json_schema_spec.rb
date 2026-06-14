require 'spec_helper'
require_relative '../../lib/ai/json_schema'

RSpec.describe AI::JSONSchema do
  let(:schema) do
    described_class.object(lang: { type: 'string', pattern: '^[a-z]{2}$' })
  end

  it 'builds object schemas with required properties' do
    expect(schema).to include(
      type:                 'object',
      additionalProperties: false,
      required:             ['lang']
    )
  end

  it 'builds a schema prompt that includes the schema and input' do
    prompt = described_class.schema_prompt('Detect language.', schema, 'Text: ola')

    expect(prompt).to include('Detect language.')
    expect(prompt).to include(JSON.dump(schema))
    expect(prompt).to include('Text: ola')
  end

  it 'parses valid fenced JSON and validates it against the schema' do
    expect(described_class.parse("```json\n{\"lang\":\"pt\"}\n```", schema: schema)).to eq('lang' => 'pt')
  end

  it 'asks any backend with a schema prompt and validates the response' do
    backend = double
    captured_prompt = nil

    allow(backend).to receive(:prompt) do |prompt, model: nil|
      captured_prompt = prompt
      '{"lang":"pt"}'
    end

    data = described_class.ask(
      backend: backend,
      task:    'Detect language.',
      schema:  schema,
      input:   'Text: ola',
      model:   nil
    )

    expect(data).to eq('lang' => 'pt')
    expect(captured_prompt).to include(JSON.dump(schema))
    expect(captured_prompt).to include('Text: ola')
  end

  it 'rejects JSON that does not match the schema' do
    expect { described_class.parse('{"lang":"portuguese"}', schema: schema) }
      .to raise_error(/schema validation failed/)
  end
end
