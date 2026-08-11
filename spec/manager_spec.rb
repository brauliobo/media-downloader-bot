require 'spec_helper'

RSpec.describe Manager do
  it 'serializes generated media upload errors for DRb clients' do
    manager = described_class.new
    bot     = double
    allow(manager).to receive(:bot).and_return(bot)
    allow(bot).to receive(:upload_generated_media).and_raise(StandardError, 'upload failed')

    error = begin
      manager.upload_generated_media(chat_id: 123, type: :audio)
      nil
    rescue RuntimeError => e
      e
    end

    expect(error.message).to eq('StandardError: upload failed')
    expect(error.cause).to be_nil
  end

  describe '#react' do
    it 'handles /stop without enqueueing it as a job' do
      manager = described_class.new
      bot     = double
      msg     = SymMash.new(from: {id: 123}, chat: {id: 456}, text: '/stop')
      manager.instance_variable_set(:@bot, bot)
      job       = manager.jobs.submit(SymMash.new(from: {id: 123}, chat: {id: 456}, text: 'url'))
      other_job = manager.jobs.submit(SymMash.new(from: {id: 123}, chat: {id: 789}, text: 'url'))

      expect(bot).to receive(:send_message).with(msg, Bot::MsgHelpers.me('Stopping 1 job...'))

      manager.react(msg)

      expect(manager.jobs.cancelled?(job[:id])).to be(true)
      expect(manager.jobs.cancelled?(other_job[:id])).to be(false)
      expect(manager.queue_size).to eq(2)
    end

    it 'reports when /stop has no active jobs' do
      manager = described_class.new
      bot     = double
      msg     = SymMash.new(from: {id: 123}, chat: {id: 456}, text: '/stop@media_bot')
      manager.instance_variable_set(:@bot, bot)

      expect(bot).to receive(:send_message).with(msg, Bot::MsgHelpers.me('No active jobs to stop.'))

      manager.react(msg)
    end
  end
end
