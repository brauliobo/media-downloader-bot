require 'spec_helper'

RSpec.describe Utils::HTTP do
  after { described_class.reset! }

  describe '.client' do
    it 'does not keep HTTP connections alive' do
      agent = described_class.client

      expect(agent.keep_alive).to be(false)
      expect(agent.idle_timeout).to eq(0)
    end
  end

  describe '.reset!' do
    it 'drops the thread-local agent' do
      first = described_class.client
      described_class.reset!

      expect(described_class.client).not_to equal(first)
    end
  end

  describe '.post' do
    it 'retries through the shared HTTP helper' do
      calls = 0
      agent = stub_http_client
      allow(Kernel).to receive(:sleep)
      allow(agent).to receive(:post) do
        calls += 1
        raise EOFError if calls == 1

        :ok
      end

      expect(described_class.post('http://example.test', '{}')).to eq(:ok)
      expect(calls).to eq(2)
    end
  end
end
