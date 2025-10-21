require_relative '../downloaders/base'

module Downloaders
  class Telegram < Base
    # Downloads a file from a public t.me link using TDLib.
    # Returns a single input object (SymMash) compatible with the rest of the pipeline.
    def download
      rx = %r{https?://t\.me/(?:(?<slug>[A-Za-z0-9_]+)/(?<msg>\d+)|c/(?<cid>-?\d+)/(?<msg2>\d+))}
      m  = url.to_s.match(rx)
      return processor.st.error('Invalid t.me link') unless m

      td = processor.bot.td

      chat_id, message_id = if m[:slug]
        chat   = td.search_public_chat(username: m[:slug]).value
        [chat.id, m[:msg].to_i]
      else
        [ ("-100#{m[:cid]}").to_i, m[:msg2].to_i ]
      end

      msg_data = td.get_message(chat_id: chat_id, message_id: message_id).value

      file_id, file_name = case msg_data.content
      when TD::Types::MessageContent::Document
        [msg_data.content.document.document.id, msg_data.content.document.file_name]
      when TD::Types::MessageContent::Audio
        [msg_data.content.audio.audio.id, msg_data.content.audio.file_name]
      when TD::Types::MessageContent::Video
        [msg_data.content.video.video.id, msg_data.content.video.file_name]
      else
        return processor.st.error('Unsupported t.me message type')
      end

      td.download_file(file_id: file_id, priority: 1, synchronous: true)
      file_info  = td.get_file(file_id: file_id).value
      local_path = file_info.local.path

      SymMash.new(
        fn_in: local_path,
        opts:  opts,
        info:  {
          title: file_name || File.basename(local_path, File.extname(local_path)),
        },
      )
    end
  end
end
