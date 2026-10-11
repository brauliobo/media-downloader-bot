module Replay
  # The messages already handed to the bot, so a resumed replay does not convert a book twice.
  class Log < KeyedLog
    self.fields = %i[chat_id id]

    def initialize(path: Rails.root.join('log/replayed.jsonl')) = super(path)

    def replayed?(chat_id, id) = include?(entry(chat_id, id))

    def record(chat_id, id) = add(entry(chat_id, id))

    private

    def entry(chat_id, id) = { chat_id: chat_id, id: id }
  end
end
