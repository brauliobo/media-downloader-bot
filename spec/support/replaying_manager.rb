# A manager that only records the replayed messages (fails the ones in `failing`, blocks on `gate` until it is fed).
class ReplayingManager
  attr_reader :replayed

  def initialize(chats: [], failing: [], gate: nil)
    @chats    = chats
    @gate     = gate
    @failing  = failing
    @replayed = []
  end

  def list_chats(query = nil) = @chats

  def replay_message(chat_id:, message_id:)
    @gate&.pop
    raise 'cannot be replayed' if @failing.include?(message_id)

    @replayed << { chat_id: chat_id, id: message_id }
  end
end
