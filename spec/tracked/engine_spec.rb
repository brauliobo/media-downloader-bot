require 'rails_helper'

RSpec.describe Tracked::Engine do
  let(:handler_class) do
    Class.new(Tracked::Handler) do
      attr_reader :peak

      def initialize(gate: nil, failing: [])
        @gate, @failing, @peak, @running = gate, failing, 0, 0
        @lock = Mutex.new
      end

      def seed(job) = job.options[:keys].map { |key| { key: key, status: 'pending', error: nil, result: Sequel.pg_jsonb({}) } }

      def describe(item) = item.key == 'x' ? raise('gone') : { file_name: "#{item.key}.pdf" }

      def perform(job, item)
        @lock.synchronize { @peak = [@peak, @running += 1].max }
        @gate&.pop
        sleep 0.05
        raise 'boom' if @failing.include?(item.key)

        { hashtags: '#A', messages: [{ chat_id: -1, message_id: item.id, kind: 'Audio', failed: false, hashtags: '#A' }] }
      ensure
        @lock.synchronize { @running -= 1 }
      end

      def retag(item)
        raise 'no yml was posted' if item.key == 'b'

        item.update(result: item.outcome.merge(hashtags: '#New'))
      end
    end
  end
  let(:handler) { handler_class.new }
  let(:engine)  { described_class.new({ 'fake' => handler }, tick: 0.01) }

  after { Job.dataset.delete }

  def start(parallel: 2, keys: %w[a b c]) = engine.start(kind: 'fake', parallel: parallel, params: { keys: keys })

  def settled(id, *states) = Timeout.timeout(5) { sleep 0.01 until Job[id].state.in?(states) }.then { Job[id] }

  it 'runs every item, tracks the counts and the messages sent for each' do
    job = settled(start[:id], 'completed')

    expect(job.counts).to eq('done' => 3)
    expect(JobItem.where(job_id: job.id).map(&:attempts)).to eq([1, 1, 1])
    expect(JobMessage.select_map(:message_id)).to match_array(JobItem.select_map(:id))
    expect(JobItem.first.outcome).to include(hashtags: '#A')
  end

  describe 'making the hashtags of finished items again' do
    let(:items) { JobItem.where(job_id: settled(start[:id], 'completed').id).order(:id).to_hash(:key) }

    it 'makes them for one item and returns it, or raises what went wrong' do
      expect(engine.retag(items['a'].id)).to include(result: include('hashtags' => '#New'))
      expect { engine.retag(items['b'].id) }.to raise_error('no yml was posted')
    end

    it 'makes them for many in the background, logging the ones that fail and going on with the others' do
      allow(engine).to receive(:warn)

      expect(engine.retag_items(items.values.map(&:id))).to eq(3)
      Timeout.timeout(5) { sleep 0.01 until items['c'].refresh.outcome[:hashtags] == '#New' }

      expect(items['a'].refresh.outcome[:hashtags]).to eq('#New')
      expect(items['b'].refresh.outcome[:hashtags]).to eq('#A')
      expect(engine).to have_received(:warn).with("item #{items['b'].id}: retag: RuntimeError: no yml was posted")
    end
  end

  it 'records what each item is about before it runs and keeps it with the outcome; an item that cannot be described says why' do
    gate = Queue.new
    engine = described_class.new({ 'fake' => handler_class.new(gate: gate) }, tick: 0.01)
    job    = engine.start(kind: 'fake', parallel: 1, params: { keys: %w[a x] })
    sleep 0.05 until JobItem.running.any?

    expect(JobItem.order(:id).map { |item| item.outcome[:input] }).to eq([{ file_name: 'a.pdf' }, { error: 'RuntimeError: gone' }])

    2.times { gate << true }
    settled(job[:id], 'completed')
    expect(JobItem.first(key: 'a').outcome).to include(input: { file_name: 'a.pdf' }, hashtags: '#A')
  end

  it 'keeps a standing job running with nothing pending and runs the items added to it' do
    handler = handler_class.new
    handler.define_singleton_method(:standing?) { |_job| true }
    engine = described_class.new({ 'fake' => handler }, tick: 0.01)
    job    = engine.start(kind: 'fake', params: { keys: [] })
    sleep 0.05

    expect(Job[job[:id]].state).to eq('running')
    expect(engine.add(job[:id], 'late')).to have_attributes(kind: 'fake', key: 'late')
    Timeout.timeout(5) { sleep 0.01 until JobItem.first(key: 'late').status == 'done' }
    expect(JobItem.first(key: 'late').outcome).to include(input: { file_name: 'late.pdf' })
    expect(engine.add(job[:id], 'late').id).to eq(JobItem.first(key: 'late').id)
    engine.stop(job[:id])
    settled(job[:id], 'stopped')
  end

  it 'lets the handler tell an item added to a job that it waits, or settle it at once, but not one it already had' do
    told = []
    handler = handler_class.new
    handler.define_singleton_method(:standing?) { |_job| true }
    handler.define_singleton_method(:queued) { |item| (told << item.key) && (item.key == 'dup' ? { duplicate_of: 'a', messages: [] } : nil) }
    engine = described_class.new({ 'fake' => handler }, tick: 3600)
    job    = engine.start(kind: 'fake', params: { keys: [] })
    sleep 0.05

    %w[late dup late].each { |key| engine.add(job[:id], key) }
    Timeout.timeout(5) { sleep 0.01 until told.size == 2 }

    expect(told).to contain_exactly('late', 'dup')
    expect(JobItem.first(key: 'dup')).to have_attributes(status: 'done').and(satisfy { |item| item.outcome[:duplicate_of] == 'a' })
    expect(JobItem.first(key: 'late').status).to eq('pending')
    engine.stop(job[:id])
  end

  it 'never has more items in flight than the job allows' do
    settled(start(parallel: 2, keys: %w[a b c d e])[:id], 'completed')

    expect(handler.peak).to eq(2)
  end

  it 'fails the item that raised, finishes the others and retries it on demand' do
    handler = handler_class.new(failing: %w[b])
    engine  = described_class.new({ 'fake' => handler }, tick: 0.01)
    job     = settled(engine.start(kind: 'fake', params: { keys: %w[a b c] })[:id], 'failed')

    expect(job.counts).to eq('done' => 2, 'failed' => 1)
    expect(JobItem.failed.first).to have_attributes(key: 'b', error: 'RuntimeError: boom')

    handler.instance_variable_set(:@failing, [])
    expect(engine.retry_items(JobItem.failed.select_map(:id))).to eq(1)
    expect(settled(job.id, 'completed').counts).to eq('done' => 3)
  end

  it 'stops after the items in flight and resumes with what is pending' do
    gate = Queue.new
    handler = handler_class.new(gate: gate)
    engine  = described_class.new({ 'fake' => handler }, tick: 0.01)
    job     = engine.start(kind: 'fake', parallel: 1, params: { keys: %w[a b c] })
    sleep 0.05 until JobItem.running.any?

    expect(engine.stop(job[:id])).to include(state: 'stopping')
    gate << :go
    expect(settled(job[:id], 'stopped').counts).to eq('done' => 1, 'pending' => 2)

    engine.resume(job[:id])
    3.times { gate << :go }
    expect(settled(job[:id], 'completed').counts).to eq('done' => 3)
  end

  it 'stops a queued job at once' do
    gate = Queue.new
    engine = described_class.new({ 'fake' => handler_class.new(gate: gate) }, tick: 0.01)
    engine.start(kind: 'fake', parallel: 1, params: { keys: %w[a] })
    queued = engine.start(kind: 'fake', params: { keys: %w[b] })

    expect(engine.stop(queued[:id])).to include(state: 'stopped')
    gate << :go
    Timeout.timeout(5) { sleep 0.01 until Job.unfinished.empty? }
  end

  it 'changes the parallelism of a job, with no ceiling but one slot' do
    job = start

    expect(engine.update(job[:id], parallel: 50)).to include(parallel: 50)
    expect(engine.update(job[:id], parallel: 0)).to include(parallel: 1)
    expect(engine.update(job[:id], parallel: 1)).to include(parallel: 1) # nothing changed
    settled(job[:id], 'completed')
  end

  it 'puts the items a dead process left running back in line and continues the unfinished jobs' do
    job  = Job.create(kind: 'fake', state: 'running', parallel: 2, params: { keys: %w[a b] })
    JobItem.create(job_id: job.id, kind: 'fake', key: 'a', status: 'running', attempts: 1)

    engine.recover!

    expect(settled(job.id, 'completed').counts).to eq('done' => 2)
    expect(JobItem.first(key: 'a').attempts).to eq(2)
  end

  it 'fails the job when the handler cannot seed it' do
    job = engine.start(kind: 'fake', params: {})

    expect(settled(job[:id], 'failed').error).to match(/NoMethodError/)
  end

  it 'rejects an unknown kind' do
    expect { engine.start(kind: 'nope') }.to raise_error(ArgumentError, /unknown job kind/)
  end
end
