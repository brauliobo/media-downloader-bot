require 'spec_helper'

RSpec.describe Bot::Jobs do
  let(:msg) do
    SymMash.new(from: {id: 123}, chat: {id: 123}, text: 'https://example.com', bot: Object.new, resp: {id: 1})
  end

  it 'queues a serializable job envelope and tracks its lifecycle' do
    jobs = described_class.new
    job  = jobs.submit(msg)

    expect(job).to include(id: be_a(String), owner_id: 123, chat_id: 123, message: include(text: 'https://example.com'))
    expect(job[:message]).not_to include(:bot, :resp)
    expect(jobs.size).to eq(1)
    expect(jobs.dequeue).to eq(job)
    expect(jobs.cancelled?(job[:id])).to be(false)
    expect(jobs.finish(job[:id])).to be(true)
    expect(jobs.cancel(job[:id], user_id: 123, chat_id: 123)).to eq(:not_found)
  end

  it 'registers inline jobs without adding them to the external queue' do
    jobs = described_class.new
    job  = jobs.register(msg)

    expect(jobs.size).to eq(0)
    expect(jobs.cancel(job[:id], user_id: 123, chat_id: 123)).to eq(:cancelled)
  end

  it 'only lets the owner or an admin cancel a job' do
    jobs = described_class.new
    job  = jobs.submit(msg)

    expect(jobs.cancel(job[:id], user_id: 456, chat_id: 123)).to eq(:forbidden)
    expect(jobs.cancel(job[:id], user_id: 123, chat_id: 456)).to eq(:forbidden)
    expect(jobs.cancel(job[:id], user_id: 456, chat_id: 456, admin: true)).to eq(:cancelled)
    expect(jobs.cancel(job[:id], user_id: 123, chat_id: 123)).to eq(:already_cancelled)
    expect(jobs.cancelled?(job[:id])).to be(true)
  end

  it 'encodes and decodes compact cancel callback data' do
    data = described_class.cancel_data('job-id')

    expect(data).to eq('job:cancel:job-id')
    expect(described_class.cancel_id(data)).to eq('job-id')
    expect(described_class.cancel_id('unrelated')).to be_nil
  end
end

RSpec.describe Manager, '#enqueue_message' do
  around do |example|
    original = ENV['WITH_WORKER']
    ENV['WITH_WORKER'] = '1'
    example.run
  ensure
    ENV['WITH_WORKER'] = original
  end

  it 'keeps inline TGBot job state in the parent runner' do
    manager = described_class.new
    bot     = double(fork_workers?: true)
    msg     = SymMash.new(from: {id: 123}, chat: {id: 456}, text: 'url')
    runner  = double
    manager.instance_variable_set(:@bot, bot)

    allow(Bot::JobRunner).to receive(:new) do |cancelled:, finished:|
      allow(runner).to receive(:run) do |id, &_work|
        expect(manager.jobs.cancel(id, user_id: 123, chat_id: 456)).to eq(:cancelled)
        expect(cancelled.call(id)).to be(true)
        finished.call(id)
      end
      runner
    end

    manager.enqueue_message(msg)

    expect(manager.queue_size).to eq(0)
    expect(runner).to have_received(:run).with(kind_of(String))
  end
end

RSpec.describe Manager, '#cancel_job' do
  let(:msg) { SymMash.new(from: {id: 123}, chat: {id: 123}, text: 'https://example.com') }

  it 'delegates an authorized callback to the job coordinator' do
    manager  = described_class.new
    bot      = double
    job      = manager.jobs.submit(msg)
    callback = Bot::Callback.new(id: 'query', user_id: 123, chat_id: 123, data: Bot::Jobs.cancel_data(job[:id]))
    manager.instance_variable_set(:@bot, bot)

    expect(bot).to receive(:answer_callback).with(callback, text: 'Cancelling...')

    manager.cancel_job(callback)

    expect(manager.jobs.cancelled?(job[:id])).to be(true)
  end

  it 'rejects a callback from another user' do
    manager  = described_class.new
    bot      = double
    job      = manager.jobs.submit(msg)
    callback = Bot::Callback.new(id: 'query', user_id: 456, chat_id: 123, data: Bot::Jobs.cancel_data(job[:id]))
    manager.instance_variable_set(:@bot, bot)

    expect(bot).to receive(:answer_callback).with(callback, text: 'This job belongs to another user')

    manager.cancel_job(callback)

    expect(manager.jobs.cancelled?(job[:id])).to be(false)
  end

  it 'rejects the owner callback from another chat' do
    manager  = described_class.new
    bot      = double
    job      = manager.jobs.submit(msg)
    callback = Bot::Callback.new(id: 'query', user_id: 123, chat_id: 456, data: Bot::Jobs.cancel_data(job[:id]))
    manager.instance_variable_set(:@bot, bot)

    expect(bot).to receive(:answer_callback).with(callback, text: 'This job belongs to another user')

    manager.cancel_job(callback)

    expect(manager.jobs.cancelled?(job[:id])).to be(false)
  end
end
