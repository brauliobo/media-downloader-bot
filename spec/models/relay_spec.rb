require 'rails_helper'

RSpec.describe 'relay models' do
  let!(:rule) { RelayRule.create(source_chat_id: -1_001, target_chat_id: -1_002) }

  around { |example| RelayRule.db.transaction(rollback: :always, auto_savepoint: true) { example.run } }

  it 'creates a rule with its defaults' do
    expect(rule.reload).to have_attributes(filter: 'document', enabled: true, source_topic_id: nil)
    expect(rule.created_at).to be_present
  end

  it 'finds the enabled rules of a chat and topic' do
    topic = RelayRule.create(source_chat_id: -1_001, source_topic_id: 5, target_chat_id: -1_003)
    RelayRule.create(source_chat_id: -1_001, target_chat_id: -1_004, enabled: false)
    RelayRule.create(source_chat_id: -9, target_chat_id: -1_005)

    expect(RelayRule.matching(SymMash.new(chat: {id: -1_001}, topic_id: 5)).all).to contain_exactly(rule, topic)
    expect(RelayRule.matching(SymMash.new(chat: {id: -1_001})).all).to eq([rule])
  end

  it 'keeps a relayed message per rule and source message, with a summary and its links in the api hash' do
    message = RelayedMessage.create(relay_rule_id: rule.id, source_chat_id: -1_001, source_message_id: 9, target_chat_id: -1_002,
                                    source_link: 'src', content: {type: 'audio'})

    expect(message.reload.to_api).to include(status: 'pending', attempts: 0, source_link: 'src', target_link: nil, content: {'type' => 'audio'})
    expect(rule.relayed_messages).to eq([message])
    expect(message.relay_rule).to eq(rule)
    expect { RelayedMessage.create(relay_rule_id: rule.id, source_chat_id: -1_001, source_message_id: 9, target_chat_id: -1_002) }
      .to raise_error(Sequel::UniqueConstraintViolation)
  end

  it 'selects messages by status' do
    attrs = {relay_rule_id: rule.id, source_chat_id: -1_001, target_chat_id: -1_002}
    failed = RelayedMessage.create(attrs.merge(source_message_id: 1, status: 'failed'))
    pending = RelayedMessage.create(attrs.merge(source_message_id: 2))

    expect(RelayedMessage.failed.all).to eq([failed])
    expect(RelayedMessage.pending.all).to eq([pending])
    expect(RelayedMessage.retryable(0).all).to be_empty
  end

  it 'deletes its messages with the rule' do
    RelayedMessage.create(relay_rule_id: rule.id, source_chat_id: -1_001, source_message_id: 1, target_chat_id: -1_002)
    rule.destroy

    expect(RelayedMessage.count).to eq(0)
  end
end
