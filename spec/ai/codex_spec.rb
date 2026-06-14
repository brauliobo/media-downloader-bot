require 'spec_helper'
require_relative '../../lib/ai/codex'

RSpec.describe AI::Codex do
  describe '.prompt' do
    it 'runs codex exec non-interactively and returns the last message' do
      status = instance_double(Process::Status, success?: true)

      expect(Open3).to receive(:capture3) do |*args, stdin_data:|
        output_file = args[args.index('-o') + 1]
        File.write(output_file, 'answer')

        expect(args).to include('codex', 'exec', '--sandbox', 'read-only', '--ask-for-approval', 'never')
        expect(args).to include('--ephemeral', '--skip-git-repo-check', '--color', 'never')
        expect(args.last).to eq('-')
        expect(stdin_data).to eq('prompt text')

        ['', '', status]
      end

      expect(described_class.prompt('prompt text')).to eq('answer')
    end
  end

  describe '.json_prompt' do
    it 'parses json wrapped in markdown fences' do
      allow(described_class).to receive(:prompt).and_return("```json\n{\"title\":\"Hello\"}\n```")
      schema = AI::JSONSchema.object(title: { type: 'string' })

      expect(described_class.json_prompt('prompt', schema: schema)).to eq('title' => 'Hello')
    end
  end
end
