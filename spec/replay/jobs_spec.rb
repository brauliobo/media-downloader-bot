require 'rails_helper'
require 'tmpdir'
require_relative '../support/replaying_manager'

RSpec.describe Replay::Jobs do
  let(:dir)       { Dir.mktmpdir }
  let(:log)       { Replay::Log.new(path: File.join(dir, 'replayed.jsonl')) }
  let(:forwarded) { Forwarding::Log.new(path: File.join(dir, 'forwarded.jsonl')) }
  let(:manager)   { ReplayingManager.new }
  let(:jobs)      { described_class.new(manager, log: log, forwarded: forwarded) }

  before { [1, 2, 3].each { |id| forwarded.record({ chat_id: -100 }, { chat_id: -200 }, id, 10 + id) } }

  after { FileUtils.remove_entry(dir) }

  def finished(job) = Timeout.timeout(2) { sleep 0.01 until %w[completed failed].include?(jobs.fetch(job[:id])[:state]) }.then { jobs.fetch(job[:id]) }

  it 'replays the messages forwarded into the chat and exposes the progress' do
    job = jobs.start(chat_id: '-200', parallel: '50')

    expect(job).to include(state: 'queued', chat_id: -200, parallel: 10, plan: false)
    expect(finished(job)).to include(state: 'completed', total: 3, replayed: 3, skipped: 0, running: 0, errors: [])
    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(11, 12, 13)
    expect(jobs.list.map { |j| j[:id] }).to eq([job[:id]])
  end

  it 'only plans and skips what was already replayed' do
    log.record(-200, 11)
    job = jobs.start(chat_id: -200, plan: '1')

    expect(finished(job)).to include(state: 'completed', total: 3, replayed: 0, skipped: 1)
    expect(manager.replayed).to be_empty
  end

  it 'recovers the books that only failed before replaying' do
    manager = ReplayingManager.new(messages: [{ id: 99, type: 'Text', text: 'failed: EOFError', reply_to_message_id: 12 }])
    log.record(-200, 11)
    log.record(-200, 12)
    job = described_class.new(manager, log: log, forwarded: forwarded).tap { |j| @jobs = j }.start(chat_id: -200, recover: '1')

    done = Timeout.timeout(2) { sleep 0.01 until @jobs.fetch(job[:id])[:state] == 'completed' }.then { @jobs.fetch(job[:id]) }
    expect(done).to include(recovered: 1, deleted: 1, replayed: 2, skipped: 1)
    expect(manager.deleted).to eq([99])
    expect(manager.replayed.map { |m| m[:id] }).to contain_exactly(12, 13)
  end

  it 'fails the job when a message cannot be replayed' do
    manager = ReplayingManager.new(failing: [12])
    job     = described_class.new(manager, log: log, forwarded: forwarded).tap { |j| @jobs = j }.start(chat_id: -200)

    done = Timeout.timeout(2) { sleep 0.01 until @jobs.fetch(job[:id])[:state] == 'failed' }.then { @jobs.fetch(job[:id]) }
    expect(done).to include(replayed: 2)
    expect(done[:errors].first).to include(id: 12)
  end

  it 'stops a running job through its runner and keeps the snapshot JSON-safe' do
    gate    = Queue.new
    manager = ReplayingManager.new(gate: gate)
    jobs    = described_class.new(manager, log: log, forwarded: forwarded)
    job     = jobs.start(chat_id: -200, parallel: 1)
    Timeout.timeout(2) { sleep 0.01 until jobs.fetch(job[:id])[:running] == 1 }

    jobs.stop(job[:id])
    gate << :go

    done = Timeout.timeout(2) { sleep 0.01 until jobs.fetch(job[:id])[:state] == 'completed' }.then { jobs.fetch(job[:id]) }
    expect(done).to include(replayed: 1, running: 0)
    expect { JSON.generate(done) }.not_to raise_error
  end

  it 'fails the job without chat_id' do
    expect { jobs.start({}) }.to raise_error(KeyError)
  end
end
