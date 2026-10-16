# A manager that records what is replayed. Replaying a message makes the bot answer it with `answers[id]` (default: one audio
# captioned with hashtags); the ones in `failing` raise. `messages` are chat history already there, `gate` blocks a replay until fed.
class ReplayingManager
  attr_reader :replayed, :deleted, :captions, :messages

  def initialize(failing: [], gate: nil, messages: [], answers: {})
    @messages = messages
    @answers  = answers
    @deleted  = []
    @captions = []
    @gate     = gate
    @failing  = failing
    @replayed = []
    @next_id  = 1_000
  end

  def chat_messages(from_message_id: 0, limit: 20, **) = @messages.sort_by { |m| -m[:id] }.select { |m| from_message_id.zero? || m[:id] < from_message_id }.first(limit)

  def delete_messages(chat_id:, message_ids:) = @deleted.concat(message_ids).tap { @messages.reject! { |m| message_ids.include?(m[:id]) } }

  def message_link(chat_id:, message_id:) = "https://t.me/c/#{chat_id.abs}/#{message_id}"

  def replace_caption(chat_id:, message_id:, from:, to:) = @captions << { chat_id: chat_id, message_id: message_id, from: from, to: to }

  def replay_message(chat_id:, message_id:)
    @gate&.pop
    raise 'cannot be replayed' if @failing.include?(message_id)

    @replayed << { chat_id: chat_id, id: message_id }
    @answers.fetch(message_id, [{ type: 'Audio', text: "Book #{message_id}\n#Livro #Yoga" }]).each do |answer|
      @messages << { id: @next_id += 1, chat_id: chat_id, reply_to_message_id: message_id, **answer }
    end
  end
end
