module Bot
  module MessageResult
    module_function

    def dump(message)
      fields = %i[message_id id media_group_id].index_with { |field| message.try(field) }.compact
      fields.slice(:message_id, :id).empty? ? message : fields
    end

    # The id of a sent message, whether it came back as an object or as a hash.
    def id(message)
      message.try(:message_id) || message.try(:id) || (message.values_at(:message_id, :id).compact.first if message.is_a?(Hash))
    end
  end
end
