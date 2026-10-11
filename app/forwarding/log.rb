module Forwarding
  # What was already copied where; `id` is the source message and `sent_id` its copy in the target.
  class Log < KeyedLog
    self.fields = %i[from topic to to_topic id]

    def initialize(path: Rails.root.join('log/forwarded.jsonl')) = super(path)

    def sent?(source, target, message_id) = include?(entry(source, target, message_id))

    def record(source, target, message_id, sent_id) = add(entry(source, target, message_id, sent_id))

    # The copies made into a chat, oldest first.
    def copies_in(chat_id)
      records.select { |entry| entry[:to] == chat_id }.map { |entry| { chat_id: chat_id, id: entry[:sent_id] } }.sort_by { |copy| copy[:id] }
    end

    private

    def entry(source, target, message_id, sent_id = nil)
      { from: source[:chat_id], topic: source[:topic_id], to: target[:chat_id], to_topic: target[:topic_id], id: message_id, sent_id: sent_id }
    end
  end
end
