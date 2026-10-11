module TDBot
  class PostEditor
    # TDLib side of Bot::Base::CHAT_OPERATIONS: listing chats, topics and messages, copying a message and leaving a chat.
    module ChatOperations
      COPY_TIMEOUT = 300

      def list_chats(query = nil)
        return find_chats(query, limit: 50) if query.present?

        Array(td.get_chats(chat_list: nil, limit: 500).value(30)&.chat_ids).map { |id| chat_summary(td.get_chat(chat_id: id).value(15)) }
      end

      def forum_topics(chat_id:)
        topics = td.get_forum_topics(
          chat_id: chat_id, query: '', offset_date: 0, offset_message_id: 0, offset_forum_topic_id: 0, limit: 100
        ).value!(30)
        Array(topics&.topics).map { |topic| { id: topic.info.forum_topic_id, name: topic.info.name } }
      rescue TD::Error => e
        raise unless e.message.to_s.match?(/not a forum/i)

        []
      end

      def chat_messages(chat_id:, limit: 20, query: nil, filter: nil, from_message_id: 0, topic_id: nil)
        result = if query.to_s.empty? && filter.to_s.empty? && topic_id.to_i.zero?
          td.get_chat_history(
            chat_id:         chat_id,
            from_message_id: from_message_id,
            offset:          0,
            limit:           limit,
            only_local:      false
          ).value(20)
        else
          td.search_chat_messages(
            chat_id:         chat_id,
            topic_id:        message_topic(topic_id),
            query:           query.to_s,
            sender_id:       nil,
            from_message_id: from_message_id,
            offset:          0,
            limit:           limit,
            filter:          search_messages_filter(filter)
          ).value(20)
        end

        Array(result&.messages).map { |message| message_summary(message) }
      end

      # Copies a message into another chat without its original sender, optionally replacing its caption; returns the new id.
      def copy_message(from_chat_id:, message_id:, to_chat_id:, topic_id: nil, caption: nil)
        content = forwarded_content(from_chat_id, message_id, caption)
        flood_wait do
          bot.send(:throttle!)
          sent = send_message_content(to_chat_id, topic_id.to_i, content)
          bot.send(:wait_for_media_send, SymMash.new(message_id: sent.id), timeout: COPY_TIMEOUT).message_id
        end
      end

      def delete_messages(chat_id:, message_ids:)
        message_ids.each_slice(100) { |ids| td.delete_messages(chat_id: chat_id, message_ids: ids, revoke: true).value!(30) }
      end

      # The stored message as the handler would build it on arrival, even when the own account sent it.
      def incoming_message(chat_id:, message_id:)
        message = td.get_message(chat_id: chat_id, message_id: message_id).value!(20)
        bot.message_handler.create_message_object(message).tap { |msg| msg.is_outgoing = false }
      end

      def message_link(chat_id:, message_id:) = MessageLink.url(chat_id: chat_id, message_id: message_id)

      def leave_chat(chat_id:)
        td.leave_chat(chat_id: chat_id).value!(30)
      end

      private

      # Telegram's flood wait fails a send with how long to wait; sleep that long and send again.
      def flood_wait(attempts: 5)
        yield
      rescue => e
        raise unless bot.send(:rate_limited?, e) && (attempts -= 1).positive?

        seconds = bot.send(:retry_after_seconds, e) + 1
        bot.send(:log_rate_limit, 'copy_message', seconds)
        sleep seconds
        retry
      end

      def message_topic(forum_topic_id)
        TD::Types::MessageTopic::Forum.new(forum_topic_id: forum_topic_id.to_i) if forum_topic_id.to_i.positive?
      end

      def forwarded_content(from_chat_id, message_id, caption)
        copy_options = { '@type' => 'messageCopyOptions', 'send_copy' => true, 'replace_caption' => caption.present?,
                         'new_caption' => ({ '@type' => 'formattedText', 'text' => caption, 'entities' => [] } if caption.present?),
                         'new_show_caption_above_media' => false }
        { '@type' => 'inputMessageForwarded', 'from_chat_id' => from_chat_id, 'message_id' => message_id,
          'in_game_share' => false, 'replace_video_start_timestamp' => false, 'new_video_start_timestamp' => 0,
          'copy_options' => copy_options }
      end
    end
  end
end
