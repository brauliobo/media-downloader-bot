require 'rails_helper'
require 'tmpdir'
require_relative '../support/replaying_manager'

RSpec.describe Replay::Handler do
  let(:dir)       { Dir.mktmpdir }
  let(:legacy)    { Replay::Log.new(path: File.join(dir, 'replayed.jsonl')) }
  let(:forwarded) { Forwarding::Log.new(path: File.join(dir, 'forwarded.jsonl')) }
  let(:manager)   { ReplayingManager.new }
  let(:engine)    { Tracked::Engine.new({ 'replay' => described_class.new(manager, forwarded: forwarded, replayed: legacy) }, tick: 0.01) }

  before { [1, 2, 3].each { |id| forwarded.record({ chat_id: -100 }, { chat_id: -200 }, id, 10 + id) } }

  after do
    Job.dataset.delete
    FileUtils.remove_entry(dir)
  end

  def run(**params) = engine.start(kind: 'replay', params: { chat_id: -200, **params }, parallel: 3)[:id].then { |id| settled(id) }

  def settled(id) = Timeout.timeout(5) { sleep 0.01 until Job[id].state.in?(%w[completed failed stopped]) }.then { Job[id] }

  it 'replays the messages forwarded into the chat and tracks every message the bot sent, with its hashtags' do
    job = run

    expect(job).to have_attributes(state: 'completed', parallel: 3)
    expect(job.counts).to eq('done' => 3)
    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(11, 12, 13)
    item = JobItem.first(key: '-200:11')
    expect(item.outcome).to include(hashtags: '#Livro #Yoga', options: '', input: { type: 'document', file_name: 'Book 11.pdf', inputs: [{ opts: { lang: 'pt' } }] })
    expect(item.messages.first).to have_attributes(chat_id: -200, kind: 'Audio', failed: false, hashtags: '#Livro #Yoga', link: "https://t.me/c/200/#{item.messages.first.message_id}")
  end

  it 'imports the legacy log: the books the bot answered are done and tracked, not replayed again' do
    legacy.record(-200, 11)
    manager.messages << { id: 500, chat_id: -200, type: 'Audio', text: "Book\n#Old", reply_to_message_id: 11 }

    run

    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(12, 13)
    expect(JobItem.done.count).to eq(3)
    expect(JobItem.first(key: '-200:11')).to have_attributes(attempts: 0)
    expect(JobItem.first(key: '-200:11').messages.map(&:message_id)).to eq([500])
    expect(JobItem.first(key: '-200:11').outcome).to include(hashtags: '#Old')
  end

  it 'replays again the legacy books the bot never answered, because the process died with them' do
    legacy.record(-200, 11)

    run

    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(11, 12, 13)
  end

  it 'fails the book the bot only answered with an error and retries it, deleting the error reply first' do
    manager = ReplayingManager.new(answers: { 12 => [{ type: 'Text', text: 'failed: EOFError' }] })
    engine  = Tracked::Engine.new({ 'replay' => described_class.new(manager, forwarded: forwarded, replayed: legacy) }, tick: 0.01)
    id      = engine.start(kind: 'replay', params: { chat_id: -200 })[:id]
    Timeout.timeout(5) { sleep 0.01 until Job[id].state == 'failed' }

    expect(JobItem.failed.first).to have_attributes(key: '-200:12', error: 'the bot only answered with an error')
    expect(JobMessage.failures.count).to eq(1)

    manager.instance_variable_set(:@answers, {})
    engine.retry_items(JobItem.failed.select_map(:id))
    Timeout.timeout(5) { sleep 0.01 until Job[id].state == 'completed' }

    expect(manager.deleted).to eq(JobMessage.failures.select_map(:message_id))
    expect(JobMessage.failures.live.count).to eq(0)
    expect(JobItem.first(key: '-200:12')).to have_attributes(status: 'done', attempts: 2)
  end

  it 'finds the books the legacy log replayed but the bot only answered with an error and retries them when asked' do
    legacy.record(-200, 11)
    legacy.record(-200, 12)
    manager = ReplayingManager.new(messages: [{ id: 99, chat_id: -200, type: 'Text', text: 'failed: EOFError', reply_to_message_id: 12 },
                                              { id: 98, chat_id: -200, type: 'Audio', text: 'Book', reply_to_message_id: 11 }])
    engine  = Tracked::Engine.new({ 'replay' => described_class.new(manager, forwarded: forwarded, replayed: legacy) }, tick: 0.01)

    id = engine.start(kind: 'replay', params: { chat_id: -200, retry_failed: '1' })[:id]
    Timeout.timeout(5) { sleep 0.01 until Job[id].state == 'completed' }

    expect(JobItem.done.count).to eq(3)
    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(12, 13)
    expect(manager.deleted).to eq([99])
  end

  it 'keeps the answers of a run that died after the bot answered, instead of converting the book twice' do
    answered = { id: 500, chat_id: -200, type: 'Audio', text: "Book\n#Old", reply_to_message_id: 11 }
    manager  = ReplayingManager.new(messages: [answered])
    engine   = Tracked::Engine.new({ 'replay' => described_class.new(manager, forwarded: forwarded, replayed: legacy) }, tick: 0.01)
    job      = Job.create(kind: 'replay', state: 'running', parallel: 1, params: { chat_id: -200 })
    JobItem.create(job_id: job.id, kind: 'replay', key: '-200:11', status: 'running', attempts: 1)

    engine.recover!
    Timeout.timeout(5) { sleep 0.01 until Job[job.id].state == 'completed' }

    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(12, 13)
    expect(JobItem.first(key: '-200:11').outcome).to include(hashtags: '#Old')
  end

  it 'converts again the book a dead run left only a status line for, deleting the line' do
    status  = { id: 500, chat_id: -200, type: 'Text', text: 'Downloading...', reply_to_message_id: 11 }
    manager = ReplayingManager.new(messages: [status])
    engine  = Tracked::Engine.new({ 'replay' => described_class.new(manager, forwarded: forwarded, replayed: legacy) }, tick: 0.01)
    job     = Job.create(kind: 'replay', state: 'running', parallel: 1, params: { chat_id: -200 })
    JobItem.create(job_id: job.id, kind: 'replay', key: '-200:11', status: 'running', attempts: 1)

    engine.recover!
    Timeout.timeout(5) { sleep 0.01 until Job[job.id].state == 'completed' }

    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(11, 12, 13)
    expect(manager.deleted).to eq([500])
    expect(JobItem.first(key: '-200:11')).to have_attributes(status: 'done')
  end

  it 'fails the book the bot answered with status lines only' do
    manager = ReplayingManager.new(answers: { 12 => [{ type: 'Text', text: 'Downloading...' }] })
    engine  = Tracked::Engine.new({ 'replay' => described_class.new(manager, forwarded: forwarded, replayed: legacy) }, tick: 0.01)
    id      = engine.start(kind: 'replay', params: { chat_id: -200 })[:id]
    Timeout.timeout(5) { sleep 0.01 until Job[id].state == 'failed' }

    expect(JobItem.first(key: '-200:12')).to have_attributes(status: 'failed', error: 'the bot sent no book')
    expect(JobItem.done.count).to eq(2)
  end

  it 'fails the book the bot never answered, as when its job vanished' do
    manager = ReplayingManager.new(answers: { 12 => [] })
    engine  = Tracked::Engine.new({ 'replay' => described_class.new(manager, forwarded: forwarded, replayed: legacy) }, tick: 0.01)
    id      = engine.start(kind: 'replay', params: { chat_id: -200 })[:id]
    Timeout.timeout(5) { sleep 0.01 until Job[id].state == 'failed' }

    expect(JobItem.first(key: '-200:12')).to have_attributes(status: 'failed', error: 'the bot sent no book')
  end

  it 'waits for the worker still converting a book after the bot restarted, instead of taking its status message for an answer' do
    status   = { id: 500, chat_id: -200, type: 'Text', text: 'Downloading...', reply_to_message_id: 11 }
    manager  = ReplayingManager.new(messages: [status], active: [11])
    engine   = Tracked::Engine.new({ 'replay' => described_class.new(manager, forwarded: forwarded, replayed: legacy) }, tick: 0.01)
    job      = Job.create(kind: 'replay', state: 'running', parallel: 1, params: { chat_id: -200 })
    JobItem.create(job_id: job.id, kind: 'replay', key: '-200:11', status: 'running', attempts: 1)

    engine.recover!
    Timeout.timeout(5) { sleep 0.01 until Job[job.id].state == 'completed' }

    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(11, 12, 13)
    expect(JobItem.first(key: '-200:11').outcome).to include(hashtags: '#Livro #Yoga')
  end

  it 'changes the hashtags in the captions of the posted media' do
    run
    item = JobItem.first(key: '-200:11')
    engine.edit(item.id, hashtags: '#Novo')
    engine.apply(item.id)

    expect(manager.captions).to eq([{ chat_id: -200, message_id: item.messages.first.message_id, from: '#Livro #Yoga', to: '#Novo' }])
    expect(item.messages.first.reload.hashtags).to eq('#Novo')
    engine.apply(item.id)
    expect(manager.captions.size).to eq(1)
  end

  it 'deletes the error replies a dead run left in the chat, tracked or not, before every run' do
    leftover = { id: 99, chat_id: -200, type: 'Text', text: 'Processing error: ArgumentError: boom', reply_to_message_id: 12 }
    manager  = ReplayingManager.new(messages: [leftover])
    engine   = Tracked::Engine.new({ 'replay' => described_class.new(manager, forwarded: forwarded, replayed: legacy) }, tick: 0.01)

    id = engine.start(kind: 'replay', params: { chat_id: -200 })[:id]
    Timeout.timeout(5) { sleep 0.01 until Job[id].state == 'completed' }

    expect(manager.deleted).to eq([99])
    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(11, 12, 13)
  end

  it 'reprocesses a done book from scratch, deleting everything sent for it' do
    run
    item = JobItem.first(key: '-200:12')
    sent = item.messages.map(&:message_id)
    item.update(attempts: 3)

    expect(engine.retry_items([item.id], discard: true)).to eq(1)
    Timeout.timeout(5) { sleep 0.01 until item.reload.status == 'done' && item.messages_dataset.live.any? }

    expect(manager.deleted).to include(*sent)
    expect(manager.replayed.map { |m| m[:id] }.count(12)).to eq(2)
    expect(item).to have_attributes(attempts: 1)
    expect(engine.retry_items([item.id])).to eq(0)
  end

  it 'deletes a tracked message from the chat and remembers it' do
    run
    message = JobItem.first(key: '-200:13').messages.first

    expect(engine.delete_message(message.id)).to include(deleted_at: be_present)
    expect(manager.deleted).to eq([message.message_id])
    expect(JobMessage.live.count).to eq(2)
  end
end
