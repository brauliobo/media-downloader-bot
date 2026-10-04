module Bot
  Callback = Struct.new(:id, :user_id, :chat_id, :message_id, :data, keyword_init: true)
end
