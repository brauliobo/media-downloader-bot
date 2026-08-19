require 'spec_helper'

RSpec.describe Worker, 'input concurrency' do
  let(:msg) { SymMash.new(from: {id: 123}, chat: {id: 123}) }
  let(:worker) { described_class.new(msg) }

  subject(:threads) { worker.send(:peach_threads) }

  before do
    allow(Bot::MsgHelpers).to receive(:from_admin?).with(msg).and_return(admin)
    worker.instance_variable_set(:@opts, opts)
  end

  context 'for regular users' do
    let(:admin) { false }
    let(:opts) { SymMash.new(threads: '10') }

    it { is_expected.to eq(1) }
  end

  context 'for admins' do
    let(:admin) { true }

    context 'without a thread option' do
      let(:opts) { SymMash.new }

      around do |example|
        previous = ENV['THREADS']
        ENV['THREADS'] = '6'
        example.run
      ensure
        ENV['THREADS'] = previous
      end

      it { is_expected.to eq(6) }
    end

    context 'with a thread option' do
      let(:opts) { SymMash.new(threads: '4') }

      it { is_expected.to eq(4) }
    end
  end
end
