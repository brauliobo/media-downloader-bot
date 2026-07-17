require 'spec_helper'
require_relative '../../lib/bot/tg_bot'

RSpec.describe Bot::TgBot do
  class FakeTelegramApi
    attr_reader :deleted

    def initialize
      @deleted = []
    end

    def delete_message(**params)
      @deleted << params
      :deleted
    end
  end

  describe '#delete_message' do
    it 'performs immediate deletes synchronously' do
      bot = described_class.new
      msg = SymMash.new(chat: {id: 123}, message_id: 456)
      tg  = FakeTelegramApi.new

      bot.tg = tg

      expect(bot.delete_message(msg, 789, wait: 0)).to eq(:deleted)
      expect(tg.deleted).to eq([{chat_id: 123, message_id: 789}])
    end
  end

  describe '.dispatch_message' do
    around do |example|
      original = ENV['WITH_WORKER']
      example.run
    ensure
      ENV['WITH_WORKER'] = original
    end

    it 'keeps external-worker queue writes in the parent process' do
      ENV.delete('WITH_WORKER')
      msg = SymMash.new(message_id: 123)

      expect(Kernel).not_to receive(:fork)
      expect { |block| described_class.dispatch_message(msg, &block) }.to yield_with_args(msg)
    end

    it 'forks inline processing work' do
      ENV['WITH_WORKER'] = '1'
      allow(Kernel).to receive(:fork).and_return(42)
      allow(Process).to receive(:waitpid)

      described_class.dispatch_message(SymMash.new) { raise 'must run in child' }

      expect(Kernel).to have_received(:fork)
      expect(Process).to have_received(:waitpid).with(42)
    end
  end
end
