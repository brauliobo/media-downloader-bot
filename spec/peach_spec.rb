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

  describe '.admin_threads' do
    it 'uses one thread for non-admins' do
      expect(described_class.admin_threads(false, 10)).to eq(1)
    end

    it 'uses the explicit or default thread count for admins' do
      expect(described_class.admin_threads(true, 4)).to eq(4)
      previous = ENV['THREADS']
      ENV['THREADS'] = '6'
      expect(described_class.admin_threads(true)).to eq(6)
    ensure
      previous ? ENV['THREADS'] = previous : ENV.delete('THREADS')
    end
  end

  describe '.peach_threads' do
    it 'prefers the current peach context' do
      described_class.with_peach_threads(2) do
        expect(described_class.peach_threads(10)).to eq(2)
      end
    end
  end
end
