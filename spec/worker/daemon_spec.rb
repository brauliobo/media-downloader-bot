require 'rails_helper'

RSpec.describe Worker::Daemon do
  let(:service) { double(queue_name: 'daemon-spec', size_mb_limit: 50) }
  let(:jobs)    { Bot::Jobs.new(queue: 'daemon-spec') }
  let(:daemon)  { described_class.new(service: service) }
  let(:started) { Queue.new }
  let(:release) { Queue.new }
  let(:seen)    { [] }

  def submit(id) = jobs.submit(SymMash.new(from: { id: id }, chat: { id: id }, message_id: id, text: "book #{id}"))

  # Every job takes `seconds` (or until `release` is fed); a stop raises Bot::JobRestarted in it, as it does in a real one.
  def work_on_jobs(&body)
    allow(Worker).to receive(:new) do |msg, job_id:, **|
      double.tap { |worker| allow(worker).to receive(:process) { seen << msg.text; body ? body.call(job_id) : nil } }
    end
  end

  def hold_jobs = work_on_jobs { |job_id| started << job_id; release.pop }

  def run_daemon
    allow(daemon).to receive(:puts)
    Thread.new { daemon.run }
  end

  def signal(name) = Process.kill(name, Process.pid)

  def wait_until(seconds = 5) = Timeout.timeout(seconds) { sleep 0.02 until yield }

  around do |example|
    saved = %i[USR2 TERM INT].to_h { |name| [name, trap(name, 'DEFAULT')] }
    example.run
  ensure
    saved.each { |name, handler| trap(name, handler) }
  end

  before do
    stub_const("#{described_class}::POLL", 0.05)
    stub_const('Bot::JobRunner::CANCEL_POLL_INTERVAL', 0.05)
    stub_const('Bot::JobRunner::STOP_GRACE', 0.2)
    BotJob.dataset.delete
    allow(Worker).to receive(:prune_workdirs)
    work_on_jobs
  end

  after do
    Zipper.size_mb_limit = nil
    Bot::JobRestarted.reset!
  end

  it 'uploads no more than its bot does' do
    thread = run_daemon
    wait_until { Zipper.size_mb_limit }
    signal(:USR2)
    thread.join(5)

    expect(Zipper.size_mb_limit).to eq(50)
  end

  it 'takes one job of the queue of its bot, finishes it and ends, leaving the next one to a fresh process' do
    first  = submit(1)
    second = submit(2)
    thread = run_daemon

    expect(thread.join(5)).to be_truthy
    expect(seen).to eq(['book 1'])
    expect(jobs.active?(first[:id])).to be(false)
    expect(jobs.dequeue(worker: 'next')).to eq(second)
  end

  it 'ends once idle for its time' do
    daemon = described_class.new(service: service, idle_exit: 0.2)
    allow(daemon).to receive(:puts)

    expect(Thread.new { daemon.run }.join(5)).to be_truthy
    expect(seen).to be_empty
  end

  it 'leaves the queues of the other bots alone' do
    Bot::Jobs.new(queue: 'other').submit(SymMash.new(from: { id: 1 }, chat: { id: 1 }, message_id: 1, text: 'other'))
    thread = run_daemon
    sleep 0.3
    signal(:USR2)
    thread.join(5)

    expect(seen).to be_empty
    expect(Bot::Jobs.new(queue: 'other').size).to eq(1)
  end

  it 'drops a job that was cancelled while it ran' do
    id = submit(1)[:id]
    work_on_jobs { sleep }
    thread = run_daemon
    wait_until { BotJob.with_pk(id)&.worker }
    jobs.cancel(id, user_id: 1, chat_id: 1)
    wait_until { !jobs.active?(id) }
    signal(:USR2)

    expect(thread.join(5)).to be_truthy
  end

  it 'keeps the lease of the job in flight' do
    stub_const('BotJob::LEASE', 0.3)
    id = submit(1)[:id]
    hold_jobs
    thread = run_daemon
    started.pop
    sleep 0.7

    expect(BotJob.with_pk!(id).lease_until).to be > Time.now
    expect(jobs.dequeue(worker: 'other')).to be_nil
    release << true
    signal(:USR2)
    thread.join(5)
  end

  describe 'on USR2' do
    it 'finishes the job in flight, takes no other, and ends' do
      first  = submit(1)
      second = submit(2)
      hold_jobs
      thread = run_daemon
      started.pop
      signal(:USR2)
      sleep 0.3

      expect(thread).to be_alive
      release << true

      expect(thread.join(5)).to be_truthy
      expect(seen).to eq(['book 1'])
      expect(jobs.active?(first[:id])).to be(false)
      expect(jobs.dequeue(worker: 'next')).to eq(second)
    end

    it 'hands the job back, to be resumed, on a second signal' do
      id = submit(1)[:id]
      hold_jobs
      thread = run_daemon
      started.pop
      signal(:USR2)
      sleep 0.2
      signal(:USR2)

      expect(thread.join(5)).to be_truthy
      expect(BotJob.with_pk!(id)).to have_attributes(state: 'queued', worker: nil, attempts: 0)
    end

    it 'lets the job leave at its checkpoint, whole, instead of throwing the stop into it' do
      stub_const('Bot::JobRunner::STOP_GRACE', 30)
      id = submit(1)[:id]
      left = Queue.new
      work_on_jobs do |job_id|
        started << job_id
        loop { Bot::JobRestarted.check!; sleep 0.02 }
      rescue Bot::JobRestarted
        left << :at_checkpoint
        raise
      end
      thread = run_daemon
      started.pop
      signal(:USR2)
      sleep 0.2
      signal(:USR2)

      expect(thread.join(5)).to be_truthy
      expect(left.pop).to eq(:at_checkpoint)
      expect(BotJob.with_pk!(id)).to have_attributes(state: 'queued', worker: nil, attempts: 0)
    end
  end

  describe 'on TERM' do
    it 'waits for the job up to the drain timeout, then hands it back' do
      stub_const("#{described_class}::SIGNALS", { USR2: nil, TERM: 0.4, INT: 0.4 })
      id = submit(1)[:id]
      hold_jobs
      thread = run_daemon
      started.pop
      signal(:TERM)

      expect(thread.join(5)).to be_truthy
      expect(BotJob.with_pk!(id)).to have_attributes(state: 'queued', attempts: 0)
    end

    it 'does not cut short what USR2 waits for' do
      id = submit(1)[:id]
      hold_jobs
      thread = run_daemon
      started.pop
      signal(:USR2)
      signal(:TERM)
      sleep 0.5

      expect(thread).to be_alive
      release << true
      thread.join(5)
      expect(jobs.active?(id)).to be(false)
    end
  end
end
