require 'spec_helper'
require 'timeout'

RSpec.describe 'TTS batch synthesis' do
  around do |example|
    keys = %w[THREADS TTS_CONCURRENCY]
    original = ENV.values_at(*keys)
    example.run
  ensure
    keys.zip(original).each do |key, value|
      value ? ENV[key] = value : ENV.delete(key)
    end
  end

  it 'defaults to four TTS threads instead of generic peach concurrency' do
    backend = Class.new do
      class << self
        attr_accessor :started, :release

        def synthesize_batch(items:, **)
          started << [items.size, Thread.current[Enumerable::PEACH_THREADS]]
          release.pop
        end
      end
    end
    backend.started = Queue.new
    backend.release = Queue.new
    stub_const('TTS::BACKEND', backend)
    items = 5.times.map { |idx| { text: idx.to_s, out_path: "#{idx}.wav" } }
    result = Queue.new
    completed = Queue.new

    ENV['THREADS'] = '10'
    ENV.delete('TTS_CONCURRENCY')
    worker = Thread.new do
      result << TTS.synthesize_batch(items: items, on_batch: ->(batch) { completed << batch.size })
    end

    expect(4.times.map { Timeout.timeout(1) { backend.started.pop } }).to eq([[1, 4]] * 4)
    expect { Timeout.timeout(0.1) { backend.started.pop } }.to raise_error(Timeout::Error)
    backend.release << true
    expect(Timeout.timeout(1) { backend.started.pop }).to eq([1, 4])
    4.times { backend.release << true }
    worker.join
    expect(result.pop).to eq(items.map { |item| item[:out_path] })
    expect(5.times.map { completed.pop }.sort).to eq([1, 1, 1, 1, 1])
  ensure
    5.times { backend&.release&.push(true) }
    worker&.join
  end

  it 'uses configured TTS concurrency' do
    contexts = Queue.new
    backend = Class.new do
      define_singleton_method(:synthesize_batch) do |items:, **|
        contexts << [items.size, Thread.current[Enumerable::PEACH_THREADS]]
      end
    end
    stub_const('TTS::BACKEND', backend)
    ENV['THREADS'] = '10'
    ENV['TTS_CONCURRENCY'] = '2'

    TTS.synthesize_batch(items: 3.times.map { |idx| {text: idx.to_s, out_path: "#{idx}.wav"} })

    expect(3.times.map { contexts.pop }).to all(eq([1, '2']))
  end

  it 'runs single-item batches sequentially with one thread' do
    backend = Class.new do
      class << self
        attr_accessor :started, :release

        def synthesize_batch(items:, **)
          started << items.size
          release.pop
        end
      end
    end
    backend.started = Queue.new
    backend.release = Queue.new
    stub_const('TTS::BACKEND', backend)
    items = 4.times.map { |idx| { text: idx.to_s, out_path: "#{idx}.wav" } }
    result = Queue.new
    completed = Queue.new
    worker = Thread.new do
      Enumerable.with_peach_threads(10) do
        result << TTS.synthesize_batch(
          items: items,
          threads: 1,
          on_batch: ->(batch) { completed << batch.size }
        )
      end
    end

    expect(Timeout.timeout(1) { backend.started.pop }).to eq(1)
    expect { Timeout.timeout(0.1) { backend.started.pop } }.to raise_error(Timeout::Error)
    backend.release << true
    expect(Timeout.timeout(1) { backend.started.pop }).to eq(1)
    backend.release << true
    expect(Timeout.timeout(1) { backend.started.pop }).to eq(1)
    backend.release << true
    expect(Timeout.timeout(1) { backend.started.pop }).to eq(1)
    backend.release << true
    worker.join

    expect(result.pop).to eq(items.map { |item| item[:out_path] })
    expect(4.times.map { completed.pop }).to eq([1, 1, 1, 1])
  ensure
    4.times { backend&.release&.push(true) }
    worker&.join
  end

  it 'retries transient batch backend failures' do
    backend = Class.new do
      class << self
        attr_accessor :attempts

        def synthesize_batch(items:, **)
          self.attempts += 1
          raise 'connection closed' if attempts == 1
        end
      end
    end
    backend.attempts = 0
    stub_const('TTS::BACKEND', backend)

    TTS.synthesize_batch(items: [{text: 'test', out_path: 'test.wav'}], threads: 1)

    expect(backend.attempts).to eq(2)
  end
end
