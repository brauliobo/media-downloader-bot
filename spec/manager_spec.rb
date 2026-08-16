require 'spec_helper'
require 'open3'
require 'rbconfig'

RSpec.describe Manager do
  it 'loads the Sequel gem when lib is in the load path' do
    code = "require 'sequel'; abort unless defined?(Sequel::Model)"
    _, error, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', code)

    expect(status).to be_success, error
  end

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
    let(:manager) { described_class.new }
    let(:bot)     { double }

    before do
      manager.instance_variable_set(:@bot, bot)
    end

    it 'enqueues unsupported private text' do
      manager.react(SymMash.new(from: {id: 123}, chat: {id: 123}, text: 'hello'))

      expect(manager.queue_size).to eq(1)
    end

    it 'ignores unsupported group text' do
      manager.react(SymMash.new(from: {id: 123}, chat: {id: -456}, text: 'hello'))

      expect(manager.queue_size).to eq(0)
    end

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

    it 'reports when /stop has no active jobs' do
      msg     = SymMash.new(from: {id: 123}, chat: {id: 456}, text: '/stop@media_bot')

      expect(bot).to receive(:send_message).with(msg, Bot::MsgHelpers.me('No active jobs to stop.'))

      manager.react(msg)
    end
  end
end
