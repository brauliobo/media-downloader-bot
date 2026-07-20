require 'spec_helper'

begin
  require_relative '../../lib/bot/td_bot'
  td_load_error = nil
rescue LoadError => e
  td_load_error = e
end

if td_load_error
  RSpec.describe 'Bot::TDBot cancellation support' do
    it('requires tdlib-ruby') { skip td_load_error.message }
  end
else
  RSpec.describe Bot::TDBot do
    let(:bot) { described_class.new }
    let(:msg) { SymMash.new(from: {id: 123}, chat: {id: 123}, id: 456) }
    let(:sender) { double }

    before do
      allow(bot).to receive(:message_sender).and_return(sender)
      allow(bot).to receive(:throttle!)
      described_class.message_send_outcomes.clear
    end

    it 'sends a native TDLib cancel control with status messages' do
      allow(sender).to receive(:send_text).and_return(message_id: 789)

      bot.send_message(msg, 'working', cancel_job: 'job-id')

      expect(sender).to have_received(:send_text) do |_chat_id, _text, params|
        markup = params[:reply_markup]
        expect(markup).to be_a(TD::Types::ReplyMarkup::InlineKeyboard)
        expect(markup.rows.first.first.type.data).to eq('job:cancel:job-id')
      end
    end

    it 'clears TDLib controls when status processing finishes' do
      allow(sender).to receive(:edit_message).and_return(true)

      bot.edit_message(msg, 789, text: 'failed', force: true, cancel_job: false)

      expect(sender).to have_received(:edit_message).with(
        123, 789, 'failed', parse_mode: 'MarkdownV2', reply_markup: nil
      )
      expect(bot).to have_received(:throttle!).with(123, :low, discard: false, message_id: 789)
    end

    it 'retries media after an asynchronous TDLib rate limit failure' do
      error = double(code: 429, message: 'Too Many Requests: retry after 2409')
      described_class.message_send_outcomes[789] = described_class::SendOutcome.new(error: TD::Error.new(error))
      described_class.message_send_outcomes[790] = described_class::SendOutcome.new(message_id: 900)
      allow(sender).to receive(:send_audio).and_return({message_id: 789}, {message_id: 790})
      allow(bot).to receive(:td_retry_after_seconds).and_return(0)

      result = bot.send_message(msg, '', type: :audio, file_path: __FILE__)

      expect(result.message_id).to eq(900)
      expect(sender).to have_received(:send_audio).twice
    end

    it 'propagates asynchronous media send failures' do
      error = double(code: 400, message: 'Bad Request')
      described_class.message_send_outcomes[789] = described_class::SendOutcome.new(error: TD::Error.new(error))
      allow(sender).to receive(:send_audio).and_return(message_id: 789)

      expect do
        bot.send_message(msg, '', type: :audio, file_path: __FILE__)
      end.to raise_error(TD::Error, 'Bad Request')
    end
  end
end
