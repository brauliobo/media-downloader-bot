module Bot
  module MessageResult
    module_function

    def dump(message)
      fields = %i[message_id id media_group_id].index_with { |field| message.try(field) }.compact
      fields.slice(:message_id, :id).empty? ? message : fields
    end
  end
end
