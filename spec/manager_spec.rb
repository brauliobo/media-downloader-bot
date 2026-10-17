require 'rails_helper'

RSpec.describe Manager do
  before { BotJob.dataset.delete }

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

  describe '#replay_message' do
    it 'reacts to the stored message and waits for its job to end' do
      manager = described_class.new
      bot     = double
      msg     = SymMash.new(from: {id: 123}, chat: {id: 456}, text: 'https://example.com/video')
      allow(manager).to receive(:bot).and_return(bot)
      allow(bot).to receive(:incoming_message).with(chat_id: 456, message_id: 7).and_return(msg)
      job = manager.jobs.register(msg)
      allow(manager).to receive(:react).with(msg, queued: true).and_return(job)
      Thread.new { sleep 0.2; manager.jobs.finish(job[:id]) }

      expect(manager.replay_message(chat_id: 456, message_id: 7)).to be(true)
      expect(manager.jobs.active?(job[:id])).to be(false)
    end

    it 'waits for the job a message already has instead of feeding it again' do
      manager = described_class.new
      job     = manager.jobs.submit(SymMash.new(from: {id: 123}, chat: {id: 456}, message_id: 7, text: 'https://example.com/video'))
      allow(manager).to receive(:bot).and_return(double)
      expect(manager).not_to receive(:react)
      expect(manager.message_job_active?(chat_id: 456, message_id: 7)).to be(true)
      Thread.new { sleep 0.2; manager.jobs.finish(job[:id]) }

      expect(manager.replay_message(chat_id: 456, message_id: 7)).to be(true)
      expect(manager.message_job_active?(chat_id: 456, message_id: 7)).to be(false)
    end
  end

  describe '#react' do
    let(:manager) { described_class.new }
    let(:bot)     { double }

    around do |example|
      ChatSetting.db.transaction(rollback: :always, auto_savepoint: true) do
        [-456, 456].each { |chat_id| ChatSetting.set_respond(chat_id, true) }
        example.run
      end
    end

    before do
      manager.instance_variable_set(:@bot, bot)
      allow(bot).to receive(:reply_job_id).and_return(nil)
    end

    it 'relays every message, even the ones the bot ignores' do
      msg = SymMash.new(from: {id: 123}, chat: {id: -789}, text: '', document: SymMash.new(file_name: 'file.pdf'))
      expect(manager.instance_variable_get(:@relay)).to receive(:dispatch).with(msg)

      manager.react(msg)

      expect(manager.queue_size).to eq(0)
    end

    it 'enqueues unsupported private text' do
      manager.react(SymMash.new(from: {id: 123}, chat: {id: 123}, text: 'hello'))

      expect(manager.queue_size).to eq(1)
    end

    it 'ignores unsupported group text' do
      manager.react(SymMash.new(from: {id: 123}, chat: {id: -456}, text: 'hello'))

      expect(manager.queue_size).to eq(0)
    end

    it 'ignores everything in a group that was not enabled' do
      manager.react(SymMash.new(from: {id: 123}, chat: {id: -789}, text: 'https://example.com/video'))
      manager.react(SymMash.new(from: {id: 123}, chat: {id: -789}, text: '', document: SymMash.new(file_name: 'file.pdf')))

      expect(manager.queue_size).to eq(0)
    end

    context 'with the group enabled' do
      it 'enqueues group URLs' do
        manager.react(SymMash.new(from: {id: 123}, chat: {id: -456}, text: 'https://example.com/video'))

        expect(manager.queue_size).to eq(1)
      end

      it 'enqueues group media' do
        media = {video: Object.new, audio: Object.new, document: SymMash.new(file_name: 'file.pdf')}
        media.each do |type, value|
          manager.react(SymMash.new(from: {id: 123}, chat: {id: -456}, text: '', type => value))
        end

        expect(manager.queue_size).to eq(3)
      end
    end

    it 'handles /stop without enqueueing it as a job' do
      msg     = SymMash.new(from: {id: 123}, chat: {id: 456}, text: '/stop')
      job       = manager.jobs.submit(SymMash.new(from: {id: 123}, chat: {id: 456}, text: 'url'))
      other_job = manager.jobs.submit(SymMash.new(from: {id: 123}, chat: {id: 789}, text: 'url'))

      expect(bot).to receive(:send_message).with(msg, Bot::MsgHelpers.me('Stopping 1 job...'))

      manager.react(msg)

      expect(manager.jobs.cancelled?(job[:id])).to be(true)
      expect(manager.jobs.cancelled?(other_job[:id])).to be(false)
      expect(manager.queue_size).to eq(2)
    end

    it 'cancels only the job of the status message a /stop replies to' do
      msg       = SymMash.new(from: {id: 123}, chat: {id: 456}, text: '/stop', reply_to_message_id: 9)
      job       = manager.jobs.submit(SymMash.new(from: {id: 123}, chat: {id: 456}, text: 'url'))
      other_job = manager.jobs.submit(SymMash.new(from: {id: 123}, chat: {id: 456}, text: 'url'))
      allow(bot).to receive(:reply_job_id).with(msg).and_return(job[:id])

      expect(bot).to receive(:send_message).with(msg, Bot::MsgHelpers.me('Cancelling...'))

      manager.react(msg)

      expect(manager.jobs.cancelled?(job[:id])).to be(true)
      expect(manager.jobs.cancelled?(other_job[:id])).to be(false)
    end

    it 'reports when /stop has no active jobs' do
      msg     = SymMash.new(from: {id: 123}, chat: {id: 456}, text: '/stop@media_bot')

      expect(bot).to receive(:send_message).with(msg, Bot::MsgHelpers.me('No active jobs to stop.'))

      manager.react(msg)
    end

    it 'cancels inline WITH_WORKER jobs from /stop' do
      original = ENV['WITH_WORKER']
      ENV['WITH_WORKER'] = '1'
      runner   = double
      allow(bot).to receive(:fork_workers?).and_return(true)
      allow(Bot::JobRunner).to receive(:new) do |**|
        allow(runner).to receive(:run)
        runner
      end
      job = manager.enqueue_message(SymMash.new(from: {id: 123}, chat: {id: 456}, text: 'https://example.com/video'))
      msg = SymMash.new(from: {id: 123}, chat: {id: 456}, text: '/stop')
      expect(job).to include(id: be_a(String), chat_id: 456)

      expect(bot).to receive(:send_message).with(msg, Bot::MsgHelpers.me('Stopping 1 job...'))

      manager.react(msg)
    ensure
      ENV['WITH_WORKER'] = original
    end
  end
end
