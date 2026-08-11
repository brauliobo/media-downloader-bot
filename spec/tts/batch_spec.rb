require 'spec_helper'
require 'timeout'

RSpec.describe 'TTS batch synthesis' do
  it 'runs fixed-size batches concurrently through peach' do
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

    old_threads = ENV['THREADS']
    ENV['THREADS'] = '10'
    worker = Thread.new do
      result << TTS.synthesize_batch(items: items, on_batch: ->(batch) { completed << batch.size })
    end

    expect(2.times.map { Timeout.timeout(1) { backend.started.pop } }).to eq([2, 2])
    2.times { backend.release << true }
    worker.join
    expect(result.pop).to eq(items.map { |item| item[:out_path] })
    expect(2.times.map { completed.pop }.sort).to eq([2, 2])
  ensure
    ENV['THREADS'] = old_threads
    2.times { backend&.release&.push(true) }
    worker&.join
  end

  it 'runs fixed-size batches sequentially with one thread' do
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
      result << TTS.synthesize_batch(
        items: items,
        threads: 1,
        on_batch: ->(batch) { completed << batch.size }
      )
    end

    expect(Timeout.timeout(1) { backend.started.pop }).to eq(2)
    expect { Timeout.timeout(0.1) { backend.started.pop } }.to raise_error(Timeout::Error)
    backend.release << true
    expect(Timeout.timeout(1) { backend.started.pop }).to eq(2)
    backend.release << true
    worker.join

    expect(result.pop).to eq(items.map { |item| item[:out_path] })
    expect(2.times.map { completed.pop }).to eq([2, 2])
  ensure
    2.times { backend&.release&.push(true) }
    worker&.join
  end

  it 'uses single-item model batches for Chinese synthesis' do
    backend = Class.new do
      class << self
        attr_accessor :batches

        def synthesize_batch(items:, **)
          batches << items
        end
      end
    end
    backend.batches = []
    stub_const('TTS::BACKEND', backend)
    items = 3.times.map { |idx| {text: idx.to_s, lang: 'zh', out_path: "#{idx}.wav"} }

    TTS.synthesize_batch(items: items, threads: 1)

    expect(backend.batches.map(&:size)).to eq([1, 1, 1])
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
