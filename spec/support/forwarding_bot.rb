# A bot with an in-memory chat, implementing Bot::Base::CHAT_OPERATIONS.
class ForwardingBot < Bot::Base
  attr_reader :copied, :left
  attr_accessor :failing

  def initialize(message_ids: [], chats: [], topics: [], failing: [])
    @messages = message_ids.map { |id| { id: id, media: { kind: 'document' } } }
    @chats    = chats
    @topics   = topics
    @failing  = failing
    @copied   = []
    @left     = []
  end

  def list_chats(query = nil) = @chats.select { |chat| chat[:title].downcase.include?(query.to_s.downcase) }

  def forum_topics(chat_id:) = @topics

  def chat_messages(chat_id:, from_message_id: 0, limit: 20, **)
    pool = @messages.sort_by { |message| -message[:id] }
    (from_message_id.zero? ? pool : pool.select { |message| message[:id] < from_message_id }).first(limit)
  end

  def copy_message(from_chat_id:, message_id:, to_chat_id:, topic_id: nil, caption: nil)
    raise 'cannot be copied' if @failing.include?(message_id)

    @copied << { id: message_id, to: to_chat_id, topic: topic_id, caption: caption }
    1_000 + message_id
  end

  def message_link(chat_id:, message_id:) = "https://t.me/c/#{chat_id.abs}/#{message_id}"

  def leave_chat(chat_id:) = @left << chat_id
end
