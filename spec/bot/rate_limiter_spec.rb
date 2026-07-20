require 'spec_helper'
require_relative '../../lib/bot/rate_limiter'

RSpec.describe Bot::RateLimiter::Scheduler do
  subject(:scheduler) { described_class.new(0.02) }

  after { scheduler.stop }

  it 'keeps a constant interval between operations' do
    times = 3.times.map do
      scheduler.wait
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    expect(times.each_cons(2).map { |left, right| right - left }).to all(be >= 0.018)
  end

  it 'serializes concurrent operations' do
    times = Queue.new
    3.times.map do
      Thread.new do
        scheduler.wait
        times << Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end.each(&:join)

    ordered = 3.times.map { times.pop }.sort
    expect(ordered.each_cons(2).map { |left, right| right - left }).to all(be >= 0.018)
  end

  it 'queues edits without blocking when the next slot is unavailable' do
    scheduler = described_class.new(1)
    scheduler.wait
    edits = Queue.new

    result = scheduler.edit(:message) { edits << :pending }

    expect(result).to eq(:queued)
    expect(edits).to be_empty
  ensure
    scheduler&.stop
  end

  it 'coalesces pending edits to the latest update' do
    scheduler.wait
    edits = Queue.new

    scheduler.edit(:message) { edits << :old }
    scheduler.edit(:message) { edits << :latest }
    sleep 0.05

    expect(edits.pop(true)).to eq(:latest)
    expect(edits).to be_empty
  end

  it 'removes a stale pending edit before a forced update' do
    scheduler.wait
    edits = Queue.new

    scheduler.edit(:message) { edits << :old }
    scheduler.edit(:message, force: true) { edits << :final }
    sleep 0.03

    expect(edits.pop(true)).to eq(:final)
    expect(edits).to be_empty
  end
end
