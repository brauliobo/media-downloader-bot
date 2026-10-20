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

  describe 'when the subscription is rate limited' do
    let(:limited) { Mechanize::ResponseCodeError.new(Struct.new(:code).new('429')) }

    before { allow(Kernel).to receive(:sleep) }

    it 'waits and asks again until it answers' do
      answers = [-> { raise limited }, -> { raise limited }, -> { http_response(completion('answer')) }]
      allow(agent).to receive(:post) { answers.shift.call }

      expect(described_class.prompt('prompt text')).to eq('answer')
      expect(Kernel).to have_received(:sleep).with(20).ordered
      expect(Kernel).to have_received(:sleep).with(40).ordered
    end

    it 'gives up when it stays limited' do
      allow(agent).to receive(:post).and_raise(limited)

      expect { described_class.prompt('prompt text') }.to raise_error(Mechanize::ResponseCodeError)
      expect(agent).to have_received(:post).exactly(described_class::RATE_LIMITED[:tries]).times
    end

    it 'does not wait for any other refusal' do
      allow(agent).to receive(:post).and_raise(Mechanize::ResponseCodeError.new(Struct.new(:code).new('401')))

      expect { described_class.prompt('prompt text') }.to raise_error(Mechanize::ResponseCodeError)
      expect(agent).to have_received(:post).once
    end
  end

  it 'raises when the proxy refuses the request' do
    allow(agent).to receive(:post).and_return(http_response('{"error":"Invalid API key"}', code: '401'))

    expect { described_class.prompt('prompt text') }.to raise_error('cli-proxy-api failed: 401')
  end
end
