# A manager that only records the replayed messages (fails the ones in `failing`, blocks on `gate` until it is fed).
class ReplayingManager
  attr_reader :replayed, :deleted

  def initialize(chats: [], failing: [], gate: nil, messages: [])
    @chats    = chats
    @messages = messages
    @deleted  = []
    @gate     = gate
    @failing  = failing
    @replayed = []
  end

  def list_chats(query = nil) = @chats

  def chat_messages(from_message_id:, limit:, **) = @messages.sort_by { |m| -m[:id] }.select { |m| from_message_id.zero? || m[:id] < from_message_id }.first(limit)

  def delete_messages(chat_id:, message_ids:) = @deleted.concat(message_ids)

  def replay_message(chat_id:, message_id:)
    @gate&.pop
    raise 'cannot be replayed' if @failing.include?(message_id)

    @replayed << { chat_id: chat_id, id: message_id }
  end
end
