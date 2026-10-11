require 'rails_helper'
require 'tmpdir'

RSpec.describe Replay::Recovery do
  let(:dir)       { Dir.mktmpdir }
  let(:log)       { Replay::Log.new(path: File.join(dir, 'replayed.jsonl')) }
  let(:forwarded) { Forwarding::Log.new(path: File.join(dir, 'forwarded.jsonl')) }
  let(:chat)      { -200 }

  # Copies 11 (answered with audio), 12 (only an error), 13 (error, then audio), 14 (never replayed) and 15 (replayed, unanswered).
  let(:messages) do
    [{ id: 21, type: 'Audio', reply_to_message_id: 11 },
     { id: 22, type: 'Text', text: 'Audiobook generation failed: EOFError', reply_to_message_id: 12 },
     { id: 23, type: 'Text', text: 'error: busy', reply_to_message_id: 13 },
     { id: 24, type: 'Audio', reply_to_message_id: 13 },
     { id: 25, type: 'Text', text: 'processing 3/9', reply_to_message_id: 15 }]
  end
  let(:chats) do
    Class.new do
      attr_reader :deleted

      def initialize(messages) = (@messages, @deleted = messages, [])
      def chat_messages(from_message_id:, limit:, **) = @messages.sort_by { |m| -m[:id] }.select { |m| from_message_id.zero? || m[:id] < from_message_id }.first(limit)
      def delete_messages(chat_id:, message_ids:) = @deleted.concat(message_ids)
    end.new(messages)
  end
  let(:recovery) { described_class.new(chats, log: log, forwarded: forwarded) }

  before do
    (1..5).each { |id| forwarded.record({ chat_id: -100 }, { chat_id: chat }, id, 10 + id) }
    [11, 12, 13, 15].each { |id| log.record(chat, id) }
  end

  after { FileUtils.remove_entry(dir) }

  it 'deletes the error replies of the books that only failed and forgets them' do
    expect(recovery.recover(chat)).to eq(recovered: 1, deleted: 1)

    expect(chats.deleted).to eq([22])
    expect([11, 12, 13, 14, 15].map { |id| log.replayed?(chat, id) }).to eq([true, false, true, false, true])
  end

  it 'only reports with plan' do
    expect(recovery.recover(chat, plan: true)).to eq(recovered: 1, deleted: 1)

    expect(chats.deleted).to be_empty
    expect(log.replayed?(chat, 12)).to be(true)
  end

  it 'does nothing when nothing was replayed' do
    other = described_class.new(chats, log: Replay::Log.new(path: File.join(dir, 'none.jsonl')), forwarded: forwarded)

    expect(other.recover(chat)).to eq(recovered: 0, deleted: 0)
  end
end
