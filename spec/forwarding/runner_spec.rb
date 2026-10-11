require 'rails_helper'
require 'tmpdir'
require_relative '../support/forwarding_bot'

RSpec.describe Forwarding::Runner do
  let(:dir)    { Dir.mktmpdir }
  let(:log)    { Forwarding::Log.new(path: File.join(dir, 'forwarded.jsonl')) }
  let(:source) { { chat_id: -100, topic_id: 7 } }
  let(:target) { { chat_id: -200, topic_id: nil } }

  after { FileUtils.remove_entry(dir) }

  def run(bot, **opts) = described_class.new(bot, log: log).run(source: source, target: target, **opts)

  it 'copies every message oldest first, across pages, with the new caption' do
    bot   = ForwardingBot.new(message_ids: (1..250).to_a)
    state = run(bot, caption: 'lang=pt')

    expect(state).to include(total: 250, sent: 250, skipped: 0, errors: [], left: false)
    expect(bot.copied.map { |c| c[:id] }).to eq((1..250).to_a)
    expect(bot.copied).to all(include(to: -200, caption: 'lang=pt'))
  end

  it 'skips what an earlier run already copied' do
    run(ForwardingBot.new(message_ids: [1, 2]))
    bot   = ForwardingBot.new(message_ids: [1, 2, 3])
    state = run(bot)

    expect(state).to include(sent: 1, skipped: 2)
    expect(bot.copied.map { |c| c[:id] }).to eq([3])
  end

  it 'only counts when planning' do
    bot = ForwardingBot.new(message_ids: [1, 2])

    expect(run(bot, plan: true, leave: true)).to include(total: 2, sent: 0)
    expect(bot.copied).to be_empty
    expect(bot.left).to be_empty
  end

  it 'leaves the source once everything was copied' do
    bot = ForwardingBot.new(message_ids: [1, 2])

    expect(run(bot, leave: true)).to include(left: true)
    expect(bot.left).to eq([-100])
  end

  it 'reports failed messages and keeps the source' do
    bot   = ForwardingBot.new(message_ids: [1, 2, 3], failing: [2])
    state = run(bot, leave: true)

    expect(state).to include(sent: 2, left: false)
    expect(state[:errors]).to eq([{ id: 2, error: 'RuntimeError: cannot be copied' }])
    expect(bot.left).to be_empty
  end

  it 'does not leave unless asked' do
    bot = ForwardingBot.new(message_ids: [1])

    expect(run(bot)).to include(left: false)
    expect(bot.left).to be_empty
  end

  it 'tells when the bot cannot do an operation' do
    expect { run(Bot::Base.new) }.to raise_error(NotImplementedError, /chat_messages/)
  end
end
