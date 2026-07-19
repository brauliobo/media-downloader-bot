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

  describe '#send_message' do
    it 'uses the native endpoint and attachment field for the media type' do
      bot = described_class.new
      msg = SymMash.new(chat: {id: 123}, message_id: 456)
      tg  = double
      allow(bot).to receive(:throttle!)
      allow(tg).to receive(:send).and_return(double(to_h: {message_id: 789}))
      bot.tg = tg

      bot.send_message(msg, 'caption', type: :photo, file_path: __FILE__, file_mime: 'image/jpeg')

      expect(tg).to have_received(:send).with(
        'send_photo',
        hash_including(photo: an_instance_of(Faraday::UploadIO), caption: 'caption')
      )
    end

    it 'adds a cancel control for a related job' do
      bot = described_class.new
      msg = SymMash.new(chat: {id: 123}, message_id: 456)
      tg  = double
      allow(bot).to receive(:throttle!)
      allow(tg).to receive(:send).and_return(double(to_h: {message_id: 789}))
      bot.tg = tg

      bot.send_message(msg, 'working', cancel_job: 'job-id')

      expect(tg).to have_received(:send).with(
        'send_message',
        hash_including(reply_markup: an_instance_of(Telegram::Bot::Types::InlineKeyboardMarkup)),
      ) do |_endpoint, params|
        button = params[:reply_markup].inline_keyboard.first.first
        expect(button.text).to eq('Cancel')
        expect(button.callback_data).to eq('job:cancel:job-id')
      end
    end
  end

  describe '#edit_message' do
    it 'removes the cancel control when the job finishes' do
      bot = described_class.new
      msg = SymMash.new(chat: {id: 123})
      tg  = double
      allow(bot).to receive(:throttle!)
      allow(tg).to receive(:send)
      bot.tg = tg

      bot.edit_message(msg, 789, text: 'failed', cancel_job: false)

      expect(tg).to have_received(:send).with(
        'edit_message_text',
        hash_including(reply_markup: an_instance_of(Telegram::Bot::Types::InlineKeyboardMarkup)),
      )
      expect(tg).to have_received(:send) do |_endpoint, params|
        expect(params[:reply_markup].inline_keyboard).to be_empty
      end
    end
  end

  describe '.callback_from' do
    it 'normalizes Telegram callback queries' do
      query = double(
        id:      'query-id',
        from:    double(id: 123),
        message: double(chat: double(id: 456), message_id: 789),
        data:    'job:cancel:job-id',
      )

      callback = described_class.callback_from(query)

      expect(callback.to_h).to include(
        id: 'query-id', user_id: 123, chat_id: 456, message_id: 789, data: 'job:cancel:job-id'
      )
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

    it 'delegates inline process ownership to the manager' do
      ENV['WITH_WORKER'] = '1'
      msg = SymMash.new(message_id: 123)

      expect { |block| described_class.dispatch_message(msg, &block) }.to yield_with_args(msg)
    end
  end
end
