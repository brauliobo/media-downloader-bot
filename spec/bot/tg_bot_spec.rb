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
end
