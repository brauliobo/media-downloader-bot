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
end
