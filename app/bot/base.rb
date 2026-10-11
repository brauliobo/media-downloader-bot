module Bot
  class Base
    include MsgHelpers

    DEFAULT_DELETE_WAIT = 30

    def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
      puts text
      finalize_sent_message(msg, SymMash.new(result: {message_id: 1}, message_id: 1, text: text), delete: delete, delete_both: delete_both)
    end

    def send_album(msg, text, uploads:, parse_mode: 'MarkdownV2', **_params)
      puts text
      Album.new(uploads, text).items.map do |up, caption|
        type = Utils::MimeTypes.telegram_type(up)
        send_message(msg, caption, type: type, parse_mode: parse_mode, file_path: up.fn_out, file_mime: up.mime)
      end
    end

    def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params)
      puts text if text
    end

    def delete_message(msg, id, wait: nil)
      wait = delete_wait_seconds(wait)
      return perform_delete_message(msg, id) unless wait&.positive?

      Thread.new do
        sleep wait
        perform_delete_message(msg, id)
      end
    end

    def download_file(file_id_or_info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: nil)
      nil
    end

    def report_error(msg, e, context: nil)
      STDERR.puts "error: #{e.class}: #{e.message}"
    end

    def answer_callback(callback, text: nil)
    end

    def reply_job_id(_msg)
    end

    def fork_workers?
      false
    end

    # What chat forwarding needs from a bot; a bot that cannot do one of them says so.
    # list_chats(query) -> [{id:, title:, type:}]; forum_topics(chat_id:) -> [{id:, name:}]
    # chat_messages(chat_id:, topic_id:, filter:, from_message_id:, limit:) -> [{id:, media:, ...}], newest first
    # copy_message(from_chat_id:, message_id:, to_chat_id:, topic_id:, caption:) -> new message id
    # delete_messages(chat_id:, message_ids:) -> removes them for everybody
    # incoming_message(chat_id:, message_id:) -> the bot's native message object, as if just received (not outgoing)
    # message_link(chat_id:, message_id:) -> url that opens the message in telegram, nil for chats without one
    CHAT_OPERATIONS = %i[list_chats forum_topics chat_messages copy_message delete_messages incoming_message message_link leave_chat].freeze
    CHAT_OPERATIONS.each do |name|
      define_method(name) { |*, **| raise NotImplementedError, "#{self.class.name} does not support #{name}" }
    end

    private

    def finalize_sent_message(msg, response, delete: nil, delete_both: nil)
      delete_message(msg, response.message_id, wait: delete_both || delete) if (delete || delete_both) && response&.message_id

      original_id = incoming_message_id(msg)
      delete_message(msg, original_id, wait: delete_both) if delete_both && original_id

      response
    end

    def message_response(message)
      id = MessageResult.id(message)
      SymMash.new(message_id: id || 0, id: id)
    end

    def incoming_message_id(msg, *keys)
      (keys.presence || %i[message_id id]).filter_map { |key| msg[key] }.first
    end

    def delete_wait_seconds(wait)
      return nil if wait.nil? || wait == false
      return DEFAULT_DELETE_WAIT if wait == true

      wait.to_f
    end

    def perform_delete_message(_msg, _id)
    end
  end
end
