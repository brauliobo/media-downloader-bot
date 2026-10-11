require 'rails_helper'

begin
  require 'tdlib-ruby'
  Bot::TDBot
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
      allow(bot).to receive(:throttle_edit).and_yield
      described_class.message_send_outcomes.clear
      described_class.status_jobs.clear
    end

    it 'resolves a /stop reply to the job of its status message, by sent or final id' do
      allow(sender).to receive(:send_text).and_return(message_id: 789)
      bot.send_message(msg, 'working', cancel_job: 'job-id')
      described_class.message_send_outcomes[789] = described_class::SendOutcome.new(message_id: 800)

      expect(bot.reply_job_id(SymMash.new(chat: {id: 123}, reply_to_message_id: 789))).to eq('job-id')
      expect(bot.reply_job_id(SymMash.new(chat: {id: 123}, reply_to_message_id: 800))).to eq('job-id')
      expect(bot.reply_job_id(SymMash.new(chat: {id: 999}, reply_to_message_id: 800))).to be_nil
      expect(bot.reply_job_id(SymMash.new(chat: {id: 123}))).to be_nil
    end

    it 'forgets the status job once its controls are cleared' do
      allow(sender).to receive(:send_text).and_return(message_id: 789)
      allow(sender).to receive(:edit_message).and_return(true)
      bot.send_message(msg, 'working', cancel_job: 'job-id')

      bot.edit_message(msg, 789, text: 'done', cancel_job: false)

      expect(bot.reply_job_id(SymMash.new(chat: {id: 123}, reply_to_message_id: 789))).to be_nil
    end

    it 'sends status text without bot-API cancel keyboards' do
      allow(sender).to receive(:send_text).and_return(message_id: 789)

      bot.send_message(msg, 'working', cancel_job: 'job-id')

      expect(sender).to have_received(:send_text) do |_chat_id, _text, params|
        expect(params[:reply_markup]).to be_nil
      end
    end

    it 'clears TDLib controls when status processing finishes' do
      allow(sender).to receive(:edit_message).and_return(true)

      bot.edit_message(msg, 789, text: 'failed', force: true, cancel_job: false)

      expect(sender).to have_received(:edit_message).with(
        123, 789, 'failed', parse_mode: 'MarkdownV2', reply_markup: nil
      )
      expect(bot).to have_received(:throttle_edit).with(123, 789, force: true)
    end

    it 'sleeps on an asynchronous TDLib rate limit failure then re-raises' do
      error = double(code: 429, message: 'Too Many Requests: retry after 2409')
      described_class.message_send_outcomes[789] = described_class::SendOutcome.new(error: TD::Error.new(error))
      allow(sender).to receive(:send_audio).and_return(message_id: 789)
      allow(bot).to receive(:retry_after_seconds).and_return(0)

      expect do
        bot.send_message(msg, '', type: :audio, file_path: __FILE__)
      end.to raise_error(TD::Error, 'Too Many Requests: retry after 2409')
      expect(sender).to have_received(:send_audio).once
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
