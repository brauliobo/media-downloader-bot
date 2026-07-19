module Bot
  require_relative 'msg_helpers'
  require_relative '../utils/mime_types'

  class Base
    include MsgHelpers

    DEFAULT_DELETE_WAIT = 30

    def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
      puts text
      finalize_sent_message(msg, SymMash.new(result: {message_id: 1}, message_id: 1, text: text), delete: delete, delete_both: delete_both)
    end

    def send_album(msg, text, uploads:, parse_mode: 'MarkdownV2', **_params)
      puts text
      uploads.map do |up|
        type = Utils::MimeTypes.telegram_type(up.mime)
        send_message(msg, '', type: type, parse_mode: parse_mode, file_path: up.fn_out, file_mime: up.mime)
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

    def fork_workers?
      false
    end

    private

    def finalize_sent_message(msg, response, delete: nil, delete_both: nil)
      delete_message(msg, response.message_id, wait: delete_both || delete) if (delete || delete_both) && response&.message_id

      original_id = incoming_message_id(msg)
      delete_message(msg, original_id, wait: delete_both) if delete_both && original_id

      response
    end

    def incoming_message_id(msg, *keys)
      keys = %i[message_id id] if keys.empty?
      key  = keys.find { |k| msg.respond_to?(k) }
      msg.public_send(key) if key
    end

    def delete_wait_seconds(wait)
      return nil if wait.nil? || wait == false
      return DEFAULT_DELETE_WAIT if wait == true

      wait.to_f
    end

    def perform_delete_message(_msg, _id)
    end
  end

  class Mock < Base
  end
end
