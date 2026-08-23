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
end
