require 'rails_helper'

RSpec.describe AI::Ollama do
  after { Utils::HTTP.reset! }

  it 'waits its own timeout for the reply, not the one a TTS call left on the thread' do
    allow(described_class).to receive(:chat).and_call_original
    seen = nil
    allow_any_instance_of(Mechanize).to receive(:post) do |agent, *|
      seen = agent.read_timeout
      instance_double(Mechanize::Page, code: '200', body: { message: { content: 'text' } }.to_json)
    end
    Utils::HTTP.client(timeout: 120)

    expect(described_class.chat([{ role: :user, content: 'hi' }])).to eq('text')
    expect(seen).to eq(described_class::TIMEOUT)
  end

  it 'caps the output and fails when the model hit the cap instead of looping on' do
    allow(described_class).to receive(:chat).and_call_original
    body = nil
    allow_any_instance_of(Mechanize).to receive(:post) do |_, _, json|
      body = JSON.parse(json)
      instance_double(Mechanize::Page, code: '200', body: { message: { content: 'la la la' }, done_reason: 'length' }.to_json)
    end

    expect { described_class.chat([{ role: :user, content: 'hi' }]) }.to raise_error(/looping/)
    expect(body.dig('options', 'num_predict')).to eq(described_class::OPTIONS[:num_predict])
  end
end
