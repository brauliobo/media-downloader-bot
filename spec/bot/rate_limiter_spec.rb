require 'spec_helper'
require_relative '../../lib/bot/rate_limiter'

RSpec.describe Bot::RateLimiter do
  let(:bot_class) do
    Class.new do
      include Bot::RateLimiter
    end
  end
  let(:bot) { bot_class.new }

  before do
    bot_class.send_interval = 0.02
    bot_class.next_send_at  = 0.0
  end

  it 'keeps a constant interval between operations' do
    times = 3.times.map do
      bot.throttle!(123)
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    expect(times.each_cons(2).map { |left, right| right - left }).to all(be >= 0.018)
  end

  it 'serializes concurrent operations' do
    times = Queue.new
    3.times.map do
      Thread.new do
        bot_class.new.throttle!(123)
        times << Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end.each(&:join)

    ordered = 3.times.map { times.pop }.sort
    expect(ordered.each_cons(2).map { |left, right| right - left }).to all(be >= 0.018)
  end

  it 'discards optional edits when the next slot is unavailable' do
    bot.throttle!(123)

    expect(bot.throttle!(123, :low, discard: true)).to eq(:discard)
  end
end
