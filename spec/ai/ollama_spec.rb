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

  describe 'a reply that hit the output cap' do
    let(:sent) { [] }

    def reply(*done_reasons)
      allow(described_class).to receive(:chat).and_call_original
      allow_any_instance_of(Mechanize).to receive(:post) do |_, _, json|
        sent << JSON.parse(json)['options']
        instance_double(Mechanize::Page, code: '200', body: { message: { content: 'text' }, done_reason: done_reasons.shift }.to_json)
      end
    end

    it 'is asked again with the loop breaker, once, and the new reply is used' do
      reply('length', 'stop')

      expect(described_class.chat([{ role: :user, content: 'hi' }])).to eq('text')
      expect(sent.map { _1['num_predict'] }).to eq([described_class::OPTIONS[:num_predict]] * 2)
      expect(sent.map { _1['repeat_penalty'] }).to eq([nil, described_class::LOOP_BREAKER[:repeat_penalty]])
    end

    it 'fails when the model loops again' do
      reply('length', 'length')

      expect { described_class.chat([{ role: :user, content: 'hi' }]) }.to raise_error(/looping/)
      expect(sent.size).to eq(2)
    end
  end
end
