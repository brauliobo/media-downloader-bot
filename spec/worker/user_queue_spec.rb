require 'spec_helper'

RSpec.describe Worker, 'user queue integration' do
  before do
    Bot::UserQueue.instance_variable_set(:@instance, nil)
    Worker.service = Bot::Mock.new
  end

  let(:admin_id)     { Bot::MsgHelpers::ADMIN_CHAT_ID }
  let(:non_admin_id) { 424242 }

  def build_msg(user_id)
    SymMash.new from: { id: user_id }, chat: { id: user_id }, text: ''
  end

  def build_worker(user_id, &run_body)
    msg    = build_msg(user_id)
    worker = Worker.new(msg)
    worker.define_singleton_method(:run) { run_body&.call(self) }
    worker
  end

  it 'serializes concurrent jobs from the same non-admin user' do
    started = Queue.new
    gate    = Queue.new
    order   = []

    threads = 3.times.map do |i|
      Thread.new do
        worker = build_worker(non_admin_id) do
          started << i
          gate.pop
          order << i
        end
        worker.process
      end
    end

    expect(started.pop).to eq(0)
    sleep 0.1
    expect(started.size).to eq(0) # the other two are blocked on the queue

    gate << :go; expect(started.pop).to eq(1)
    sleep 0.1
    expect(started.size).to eq(0)

    gate << :go; expect(started.pop).to eq(2)
    gate << :go

    threads.each(&:join)
    expect(order).to eq([0, 1, 2])
  end

  it 'lets admins run jobs concurrently' do
    running = Concurrent::AtomicFixnum.new(0) rescue nil
    running ||= Class.new { def initialize; @m=Mutex.new;@n=0;end; def increment; @m.synchronize{@n+=1};end; def value; @m.synchronize{@n};end }.new
    peak  = 0
    pmtx  = Mutex.new
    gate  = Queue.new

    threads = 3.times.map do
      Thread.new do
        worker = build_worker(admin_id) do
          n = running.increment
          pmtx.synchronize { peak = n if n > peak }
          gate.pop
        end
        worker.process
      end
    end

    sleep 0.2
    3.times { gate << :go }
    threads.each(&:join)
    expect(peak).to eq(3)
  end

  it 'shows a Queued status line for waiting non-admin jobs and clears it on acquire' do
    queue = Bot::UserQueue.instance
    queue.acquire(non_admin_id) # occupy the only slot

    worker = build_worker(non_admin_id) { sleep 0.05 }

    statuses = []
    allow(worker).to receive(:init_status) do
      worker.instance_variable_set(:@st, Bot::Status.new { |t, *| statuses << t })
    end

    t = Thread.new { worker.process }
    sleep 0.1
    expect(statuses.last).to include(Bot::UserQueue::QUEUED_MSG)

    queue.release(non_admin_id)
    t.join

    expect(worker.st.to_a).to be_empty
  end

  it 'releases the slot when run raises' do
    queue  = Bot::UserQueue.instance
    worker = build_worker(non_admin_id) { raise 'boom' }

    expect { worker.process }.to raise_error('boom')
    expect(queue.queued?(non_admin_id)).to be false
  end
end
