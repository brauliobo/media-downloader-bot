module Replay
  # Finds the replayed messages the bot only answered with an error, deletes those error replies and forgets the
  # messages, so the next replay converts them again. `chats` offers chat_messages and delete_messages: a bot or a manager.
  class Recovery
    ERROR = /error|failed/i
    PAGE  = 100

    def initialize(chats, log: Log.new, forwarded: Forwarding::Log.new)
      @chats     = chats
      @log       = log
      @forwarded = forwarded
    end

    # plan: only report what would be recovered.
    def recover(chat_id, plan: false)
      failed = failures(chat_id)
      forget(chat_id, failed) unless plan
      { recovered: failed.size, deleted: failed.values.sum(&:size) }
    end

    private

    # { copy id => its error replies } for the replayed copies whose every reply is an error.
    def failures(chat_id)
      ids = @forwarded.copies_in(chat_id).map { |copy| copy[:id] }.select { |id| @log.replayed?(chat_id, id) }
      return {} if ids.empty?

      replies = history(chat_id, ids.min).select { |message| ids.include?(message[:reply_to_message_id]) }
      replies.group_by { |message| message[:reply_to_message_id] }.select { |_, group| group.all? { |message| failed?(message) } }
    end

    def failed?(message) = message[:type] == 'Text' && message[:text].to_s.match?(ERROR)

    def forget(chat_id, failed)
      @chats.delete_messages(chat_id: chat_id, message_ids: failed.values.flatten.map { |message| message[:id] })
      failed.each_key { |id| @log.forget(chat_id, id) }
    end

    # The messages of the chat down to `oldest`, newest first.
    def history(chat_id, oldest)
      messages, cursor = [], 0
      loop do
        page = @chats.chat_messages(chat_id: chat_id, from_message_id: cursor, limit: PAGE)
        messages.concat(page)
        break if page.empty? || page.last[:id] <= oldest || page.last[:id] == cursor

        cursor = page.last[:id]
      end
      messages
    end
  end
end
