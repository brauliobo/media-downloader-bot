require 'spec_helper'

RSpec.describe Enumerable, 'peach thread context' do
  around do |example|
    previous = Thread.current[Enumerable::PEACH_THREADS]
    example.run
  ensure
    Thread.current[Enumerable::PEACH_THREADS] = previous
  end

  it 'keeps sequential nested work at the job thread count' do
    Thread.current[Enumerable::PEACH_THREADS] = 1
    counts = []

    [1, 2].peach(threads: 10) { counts << Thread.current[Enumerable::PEACH_THREADS] }

    expect(counts).to eq([1, 1])
  end

  it 'propagates the job thread count to pool workers' do
    Thread.current[Enumerable::PEACH_THREADS] = 2
    counts = Queue.new

    [1, 2, 3].peach(threads: 10) { counts << Thread.current[Enumerable::PEACH_THREADS] }

    expect(3.times.map { counts.pop }).to all(eq(2))
  end
end
