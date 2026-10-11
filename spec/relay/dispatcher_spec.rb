require 'rails_helper'
require_relative '../support/forwarding_bot'

RSpec.describe Relay::Dispatcher do
  let(:bot)        { ForwardingBot.new }
  let(:dispatcher) { described_class.new(-> { bot }, pool: Concurrent::ImmediateExecutor.new) }
  let(:source)     { -1_001_111 }
  let(:target)     { -1_002_222 }
  let!(:rule)      { RelayRule.create(source_chat_id: source, target_chat_id: target, caption: 'Hi', target_topic_id: 7) }

  around { |example| RelayRule.db.transaction(rollback: :always, auto_savepoint: true) { example.run } }

  def document(id, chat: source, topic: nil, name: 'book.pdf')
    SymMash.new(chat: {id: chat}, id: id, topic_id: topic, text: '', document: {file_name: name, file_size: 10})
  end

  def text(id, chat: source) = SymMash.new(chat: {id: chat}, id: id, text: 'hello')

  def row(id) = RelayedMessage.first(source_message_id: id)

  it 'copies a matching message, replacing the caption, and records both links' do
    dispatcher.dispatch(document(5))

    expect(bot.copied).to eq([{id: 5, to: target, topic: 7, caption: 'Hi'}])
    expect(row(5).to_api).to include(
      status: 'sent', attempts: 1, error: nil, target_message_id: 1_005, source_link: "https://t.me/c/#{source.abs}/5",
      target_link: "https://t.me/c/#{target.abs}/1005", content: {'type' => 'document', 'file_name' => 'book.pdf', 'size' => 10}
    )
  end

  it 'keeps the original caption when the rule has none' do
    rule.update(caption: '')
    dispatcher.dispatch(document(5))

    expect(bot.copied.first).to include(caption: nil)
  end

  it 'only lets through what the filter allows' do
    dispatcher.dispatch(text(1))
    dispatcher.dispatch(document(2))
    rule.update(filter: 'all')
    dispatcher.dispatch(text(3))

    expect(bot.copied.map { |c| c[:id] }).to eq([2, 3])
    expect(row(3).content.to_h).to include('type' => 'text', 'text' => 'hello')
  end

  it 'ignores other chats and disabled rules' do
    dispatcher.dispatch(document(1, chat: -42))
    rule.update(enabled: false)
    dispatcher.dispatch(document(2))

    expect(bot.copied).to be_empty
    expect(RelayedMessage.count).to eq(0)
  end

  it 'watches a single topic when the rule has one, and every topic otherwise' do
    rule.update(source_topic_id: 3)
    dispatcher.dispatch(document(1, topic: 3))
    dispatcher.dispatch(document(2, topic: 4))
    dispatcher.dispatch(document(3))
    rule.update(source_topic_id: nil)
    dispatcher.dispatch(document(4, topic: 4))

    expect(bot.copied.map { |c| c[:id] }).to eq([1, 4])
  end

  it 'copies a message once per rule' do
    other = RelayRule.create(source_chat_id: source, target_chat_id: -1_003_333)
    2.times { dispatcher.dispatch(document(5)) }

    expect(bot.copied.map { |c| c[:to] }).to contain_exactly(target, other.target_chat_id)
    expect(RelayedMessage.where(source_message_id: 5).count).to eq(2)
  end

  describe 'a copy that fails' do
    let(:bot) { ForwardingBot.new(failing: [5]) }

    before { expect { dispatcher.dispatch(document(5)) }.to output(/relay: copy of relayed message \d+: RuntimeError/).to_stderr }

    it 'is kept as failed with its error' do
      expect(row(5)).to have_attributes(status: 'failed', attempts: 1, error: 'RuntimeError: cannot be copied', target_message_id: nil)
      expect(RelayedMessage.failed.count).to eq(1)
    end

    it 'can be retried by id' do
      bot.failing = []

      expect(dispatcher.retry(row(5).id)).to be(true)
      expect(row(5)).to have_attributes(status: 'sent', attempts: 2, error: nil)
    end

    it 'can be retried all at once' do
      bot.failing = []

      expect(dispatcher.retry_failed).to eq(1)
      expect(RelayedMessage.failed.count).to eq(0)
    end

    it 'does not retry what was already sent' do
      sent = RelayedMessage.first.update(status: 'sent')

      expect(dispatcher.retry(sent.id)).to be(false)
    end
  end

  describe '#recover!' do
    def stale(message, **values) = RelayedMessage.where(id: row(message).id).update(updated_at: Time.now - 120, **values)

    before do
      %w[1 2 3 4].each { |id| RelayedMessage.dataset.insert(relay_rule_id: rule.id, source_chat_id: source, source_message_id: id, target_chat_id: target) }
      stale(1)
      stale(3, status: 'failed', attempts: 1)
      stale(4, status: 'failed', attempts: 3)
    end

    it 'copies what was left pending a while ago and the failed ones with attempts to spare' do
      expect(dispatcher.recover!).to eq(2)

      expect(bot.copied.map { |c| c[:id] }).to contain_exactly(1, 3)
      expect(RelayedMessage.pending.select_map(:source_message_id)).to eq([2])
      expect(RelayedMessage.failed.select_map(:source_message_id)).to eq([4])
    end
  end

  it 'never raises into the caller' do
    dispatcher = described_class.new(-> { Bot::Mock.new }, pool: Concurrent::ImmediateExecutor.new)

    expect { dispatcher.dispatch(document(5)) }.to output(/relay: dispatch: NotImplementedError/).to_stderr
  end
end
