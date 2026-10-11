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
  end
end
