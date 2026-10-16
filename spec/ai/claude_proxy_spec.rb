require 'rails_helper'

RSpec.describe AI::ClaudeProxy do
  let(:agent) { stub_http_client }

  def completion(content) = { choices: [{ message: { role: 'assistant', content: content } }] }.to_json

  it 'asks the chat completions endpoint and returns the answer' do
    allow(agent).to receive(:post) do |url, body, headers|
      expect(url).to end_with('/v1/chat/completions')
      expect(JSON.parse(body)).to include('model' => described_class::MODEL, 'messages' => [{ 'role' => 'user', 'content' => 'prompt text' }])
      expect(headers).to include('Content-Type' => 'application/json', 'Authorization' => "Bearer #{described_class::KEY}")
      http_response(completion(" answer\n"))
    end

    expect(described_class.prompt('prompt text')).to eq('answer')
  end

  it 'validates JSON output against the provided schema' do
    allow(agent).to receive(:post).and_return(http_response(completion('["Health"]')))

    expect(described_class.json_prompt('return json', schema: Hashtags::HASHTAG_SCHEMA.merge(minItems: 1))).to eq(['Health'])
  end

  it 'raises when the proxy refuses the request' do
    allow(agent).to receive(:post).and_return(http_response('{"error":"Invalid API key"}', code: '401'))

    expect { described_class.prompt('prompt text') }.to raise_error('cli-proxy-api failed: 401')
  end
end
