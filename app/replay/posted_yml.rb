module Replay
  # The yml the bot posted with a book, brought back from the chat.
  class PostedYml
    def initialize(manager) = @manager = manager

    # The local path of the yml posted for the item; nil when none was.
    def path(item)
      item.messages_dataset.live.where(kind: 'Document').each do |message|
        media = @manager.chat_message(chat_id: message.chat_id, message_id: message.message_id)&.dig(:media)
        return @manager.download_file(media[:file_id], **media.slice(:remote_id)) if media&.dig(:file_name).to_s.end_with?('.yml')
      end
      nil
    end
  end
end
