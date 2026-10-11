module TDBot
  # Prepended to TD::MessageHandler: the incoming message object also carries the forum topic it was posted in.
  module MessageTopic
    def create_message_object(orig_msg)
      super.tap { |msg| msg.topic_id = orig_msg.message_thread_id if orig_msg.is_topic_message }
    end
  end
end
