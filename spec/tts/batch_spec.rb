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
end
