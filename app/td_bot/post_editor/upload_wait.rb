module TDBot
  class PostEditor
    # A sent message is pending until its file has been uploaded; this waits for that and reads the file back.
    module UploadWait
      private

      def wait_uploaded_message(chat_id, message_id)
        loop do
          actual_id = message_sender.message_id_map[message_id] || message_id
          message   = td.get_message(chat_id: chat_id, message_id: actual_id).value(30) rescue nil
          remote_id = message_remote_file_id(message) if message
          return message if remote_id.present? && message_uploaded?(message)

          sleep 2
        end
      end

      def message_uploaded?(message)
        file = message_file(message)
        file.nil? || file.remote&.is_uploading_completed
      end

      def message_file(message)
        content = message&.content
        case content
        when TD::Types::MessageContent::Audio
          content.audio.audio
        when TD::Types::MessageContent::Video
          content.video.video
        when TD::Types::MessageContent::Document
          content.document.document
        end
      end

      def message_remote_file_id(message)
        message_file(message)&.remote&.id
      end
    end
  end
end
