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
    items = 8.times.map { |idx| { text: idx.to_s, out_path: "#{idx}.wav" } }
    result = Queue.new

    old_threads = ENV['THREADS']
    ENV['THREADS'] = '10'
    worker = Thread.new { result << TTS.synthesize_batch(items: items) }

    expect(2.times.map { Timeout.timeout(1) { backend.started.pop } }).to eq([4, 4])
    2.times { backend.release << true }
    worker.join
    expect(result.pop).to eq(items.map { |item| item[:out_path] })
  ensure
    ENV['THREADS'] = old_threads
    2.times { backend&.release&.push(true) }
    worker&.join
  end
end
