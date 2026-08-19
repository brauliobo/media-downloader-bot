require 'spec_helper'
require 'timeout'

RSpec.describe Pipeline do
  around do |example|
    previous = Thread.current[Enumerable::PEACH_THREADS]
    example.run
  ensure
    Thread.current[Enumerable::PEACH_THREADS] = previous
  end

  describe '.jobs' do
    it 'splits peach threads across pipelined tasks with a minimum of 1' do
      Enumerable.with_peach_threads(10) { expect(described_class.jobs(2)).to eq(5) }
      Enumerable.with_peach_threads(1)  { expect(described_class.jobs(2)).to eq(1) }
      Enumerable.with_peach_threads(3)  { expect(described_class.jobs(2)).to eq(1) }
    end
  end

  it 'runs consume as perform finishes' do
    Enumerable.with_peach_threads(2) do
      seen = []
      described_class.each([1, 2, 3], tasks: 2, perform: ->(item) { item * 10 }) do |item, value|
        seen << [item, value]
      end
      expect(seen).to eq([[1, 10], [2, 20], [3, 30]])
    end
  end

  it 'keeps performing while batched consume runs' do
    Enumerable.with_peach_threads(4) do
      later   = Queue.new
      started = Queue.new
      release = Queue.new

      worker = Thread.new do
        described_class.each((1..6).to_a, tasks: 2, batch: 2, perform: ->(item) {
          later << item if item > 2
          item
        }) do |batch|
          started << batch
          release.pop
        end
      end

      expect(Timeout.timeout(1) { started.pop }).to eq([1, 2])
      expect(Timeout.timeout(1) { later.pop }).to be > 2
      3.times { release << true }
      worker.join
    end
  end
end
