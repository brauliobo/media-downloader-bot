module Bot
  # The id a file is downloaded by, from whatever names it: the id itself, the document holding it or its JSON form.
  module FileId
    module_function

    def call(info)
      case info
      when Integer, /\A\d+\z/ then info.to_i
      when nil then nil
      when Hash then call(info.with_indifferent_access.values_at(:document, :file_id, :id).compact.first)
      else (info.try(:document) || info.try(:file_id) || info.try(:id)).then { |inner| inner ? call(inner) : info }
      end
    end

    # The id Telegram keeps for a TD document: TDLib numbers its files per run, so the id above names another file once the bot
    # restarted, and this one does not.
    def remote(info) = info.try(:with_indifferent_access)&.dig(:document, :remote, :id).presence

    # The name a file was given, when whatever describes it carries one.
    def name(info)
      case info
      when Hash then info.with_indifferent_access[:file_name].presence
      else info.try(:file_name).presence
      end
    end
  end
end
