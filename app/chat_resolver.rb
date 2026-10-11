# Resolves chats and forum topics given by id or name against the bot's manager; aborts when there is no single match.
class ChatResolver
  def initialize(manager, output)
    @manager = manager
    @output  = output
  end

  # {chat_id:, topic_id:}, announcing the chat on the output.
  def chat_ref(name, topic = nil)
    chat = chat(name)
    @output.puts "#{chat[:title]} (#{chat[:id]})"
    { chat_id: chat[:id], topic_id: (topic_id(chat[:id], topic) if topic) }
  end

  private

  def chat(name)
    return { id: name.to_i, title: name } if name.match?(/\A-?\d+\z/)

    chats = @manager.list_chats.select { |chat| chat[:title].to_s.downcase.include?(name.downcase) }
    exact = chats.select { |chat| chat[:title].casecmp?(name) }
    chats = exact if exact.any?
    abort "no chat found for #{name.inspect}" if chats.empty?
    abort "multiple chats found; use the id: #{chats.inspect}" if chats.size > 1

    chats.first
  end

  def topic_id(chat_id, topic)
    return topic.to_i if topic.match?(/\A\d+\z/)

    found = @manager.forum_topics(chat_id: chat_id).find { |t| t[:name].casecmp?(topic) }
    (found || abort("no topic #{topic.inspect} in chat #{chat_id}"))[:id]
  end
end
