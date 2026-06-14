require 'spec_helper'
require_relative '../../lib/ai/open_code'

RSpec.describe AI::OpenCode do
  let(:schema) do
    AI::JSONSchema.object(text: { type: 'string' })
  end

  it 'clears opencode runtime environment before spawning the CLI' do
    status = instance_double(Process::Status, success?: true, exitstatus: 0)

    expect(Open3).to receive(:capture3) do |env, *cmd|
      expect(env).to include('OPENCODE' => nil, 'OPENCODE_PID' => nil)
      expect(cmd).to include('opencode', 'run', '--pure')

      ['answer', '', status]
    end

    expect(described_class.prompt('prompt text')).to eq('answer')
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
