module Bot
  module MessageResult
    module_function

    def dump(message)
      return message unless message.respond_to?(:id) || message.respond_to?(:message_id)

      {
        message_id:     message.respond_to?(:message_id) ? message.message_id : nil,
        id:             message.respond_to?(:id) ? message.id : nil,
        media_group_id: message.respond_to?(:media_group_id) ? message.media_group_id : nil,
      }.compact
    end
  end
end
