module TDBot
  # Prepended to TD::MessageHandler: the incoming message object also carries the forum topic it was posted in.
  module MessageTopic
    def create_message_object(orig_msg)
      super.tap { |msg| msg.topic_id = orig_msg.topic_id.try(:forum_topic_id) }
    end
  end
end
