module Bot
  class Base
    def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
      puts text
      SymMash.new(result: {message_id: 1}, text: text)
    end

    def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params)
      puts text if text
    end

    def delete_message(msg, id, wait: nil)
    end

    def download_file(file_id_or_info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: nil)
      nil
    end
  end

  class Mock < Base
  end
end

