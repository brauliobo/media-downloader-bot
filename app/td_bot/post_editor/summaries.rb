module TDBot
  class PostEditor
    # Chats and messages as plain hashes for the callers outside TDLib.
    module Summaries
      private

      def chat_summary(chat)
        { id: chat.id, title: chat.title, type: chat.type.class.name.split('::').last }
      end

      def message_summary(message)
        content = message.content
        {
          id:                  message.id,
          chat_id:             message.chat_id,
          date:                message.date,
          type:                content.class.name.split('::').last,
          text:                message_text(content),
          media:               message_media(content),
          reply_to_message_id: message_reply_to_id(message),
          can_edit:            message.respond_to?(:can_be_edited) ? message.can_be_edited : nil,
          sender_id:           message.sender_id.respond_to?(:user_id) ? message.sender_id.user_id : nil
        }
      end

      def message_reply_to_id(message)
        reply_to = message.reply_to if message.respond_to?(:reply_to)
        reply_to.message_id if reply_to.respond_to?(:message_id)
      end

      def message_text(content)
        formatted = if content.respond_to?(:text)
          content.text
        elsif content.respond_to?(:caption)
          content.caption
        end
        formatted.respond_to?(:text) ? formatted.text : formatted.to_s
      end

      def message_media(content)
        case content
        when TD::Types::MessageContent::Document
          file = content.document.document
          media_summary('document', file, content.document.file_name, content.document.mime_type)
        when TD::Types::MessageContent::Audio
          file = content.audio.audio
          media_summary('audio', file, content.audio.file_name, content.audio.mime_type, duration: content.audio.duration)
        when TD::Types::MessageContent::Video
          file = content.video.video
          media_summary('video', file, content.video.file_name, content.video.mime_type, duration: content.video.duration)
        end
      end

      def media_summary(kind, file, file_name, mime_type, duration: nil)
        {
          kind:      kind,
          file_id:   file.id,
          remote_id: file.remote&.id,
          file_name: file_name,
          mime_type: mime_type,
          duration:  duration
        }.compact
      end

      def search_messages_filter(filter)
        case filter.to_s
        when '', 'all' then nil
        when 'audio'  then TD::Types::SearchMessagesFilter::Audio.new
        when 'video'  then TD::Types::SearchMessagesFilter::Video.new
        when 'document', 'doc' then TD::Types::SearchMessagesFilter::Document.new
        else
          raise ArgumentError, "unsupported message filter: #{filter.inspect}"
        end
      end
    end
  end
end
