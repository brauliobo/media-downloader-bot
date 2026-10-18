require 'rails_helper'

RSpec.describe Worker, '#waiting_rate_limit' do
  subject(:worker) { described_class.new(SymMash.new(from: { id: 1 }, chat: { id: 1 })) }

  let(:refused) { RuntimeError.new('TD::Error: Too Many Requests: retry after 12') }

  before do
    stub_const("#{described_class}::RATE_LIMIT_TRIES", 3)
    allow(worker).to receive(:sleep)
    allow(worker).to receive(:warn)
  end

  it 'sends again when Telegram refused with a 429, and returns what the send returns' do
    calls = 0

    result = worker.waiting_rate_limit { (calls += 1) == 1 ? raise(refused) : :sent }

    expect(result).to eq(:sent)
    expect(calls).to eq(2)
  end

  it 'hands the job back, with its directory, when it keeps being refused' do
    calls = 0

    expect { worker.waiting_rate_limit { calls += 1; raise refused } }.to raise_error(Bot::JobRestarted, /rate limit/)
    expect(calls).to eq(3)
  end

  it 'leaves other errors alone' do
    expect { worker.waiting_rate_limit { raise 'Bad Request' } }.to raise_error('Bad Request')
  end
end
