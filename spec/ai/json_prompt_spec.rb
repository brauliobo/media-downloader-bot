require 'spec_helper'
require_relative '../../lib/ai/json_prompt'

RSpec.describe AI::JSONPrompt do
  let(:backend) do
    Class.new do
      extend AI::JSONPrompt

      def self.prompt(text, model: nil)
        JSON.dump(text: text, model: model)
      end
    end
  end

  it 'shares prompt execution and schema parsing across adapters' do
    schema = AI::JSONSchema.object(text: {type: 'string'}, model: {type: %w[string null]})

    expect(backend.json_prompt('hello', schema: schema, model: 'test')).to eq(
      'text' => 'hello', 'model' => 'test'
    )
  end
end
