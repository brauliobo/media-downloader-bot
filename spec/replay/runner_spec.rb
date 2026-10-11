require 'rails_helper'
require 'tmpdir'

RSpec.describe Replay::Runner do
  let(:dir)      { Dir.mktmpdir }
  let(:log)      { Replay::Log.new(path: File.join(dir, 'replayed.jsonl')) }
  let(:messages) { (1..10).map { |id| { chat_id: -100, id: id } } }

  # Stands in for the manager: records what it was asked and how many calls overlapped.
  let(:manager) do
    Class.new do
      attr_reader :replayed, :max_running

      def initialize(failing: [], &hook)
        @failing, @hook, @replayed, @running, @max_running, @mutex = failing, hook, [], 0, 0, Mutex.new
      end

      def replay_message(chat_id:, message_id:)
        @mutex.synchronize { @max_running = [@max_running, @running += 1].max }
        sleep 0.02
        @hook&.call(message_id)
        raise 'conversion failed' if @failing.include?(message_id)

        @mutex.synchronize { @replayed << message_id }
        true
      ensure
        @mutex.synchronize { @running -= 1 }
      end
    end
  end

  after { FileUtils.remove_entry(dir) }

  def runner(fake, **opts) = described_class.new(fake, log: log, **opts)

  it 'replays every message without exceeding the parallel cap' do
    fake  = manager.new
    state = runner(fake, parallel: 3).run(messages: messages)

    expect(state).to include(total: 10, replayed: 10, skipped: 0, running: 0, errors: [])
    expect(fake.replayed.sort).to eq((1..10).to_a)
    expect(fake.max_running).to eq(3)
  end

  it 'skips what an earlier run already replayed' do
    runner(manager.new).run(messages: messages.first(4))
    fake  = manager.new
    state = runner(fake).run(messages: messages)

    expect(state).to include(replayed: 6, skipped: 4)
    expect(fake.replayed.sort).to eq((5..10).to_a)
  end

  it 'collects failures without aborting the batch, and does not retry them' do
    fake  = manager.new(failing: [2, 5])
    state = runner(fake).run(messages: messages)

    expect(state).to include(replayed: 8, running: 0)
    expect(state[:errors]).to contain_exactly(
      { id: 2, error: 'RuntimeError: conversion failed' }, { id: 5, error: 'RuntimeError: conversion failed' }
    )
    expect(log.replayed?(-100, 2)).to be(true)
  end

  it 'stops taking new messages after stop!' do
    replay = nil
    fake   = manager.new { |id| replay.stop! if id == 2 }
    replay = runner(fake, parallel: 1)
    state  = replay.run(messages: messages)

    expect(state).to include(replayed: 2, total: 10)
    expect(log.replayed?(-100, 3)).to be(false)
  end

  it 'only counts in plan mode' do
    fake  = manager.new
    state = runner(fake).run(messages: messages, plan: true)

    expect(state).to include(total: 10, replayed: 0, skipped: 0)
    expect(fake.replayed).to be_empty
    expect(log.replayed?(-100, 1)).to be(false)
  end

  it 'reports progress after each change' do
    states = []
    runner(manager.new, parallel: 1).run(messages: messages.first(2)) { |state| states << state.deep_dup }

    expect(states.first).to include(replayed: 0, running: 0)
    expect(states.last).to include(replayed: 2, running: 0)
  end
end
