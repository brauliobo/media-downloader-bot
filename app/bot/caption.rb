module Bot
  module Caption
    module_function

    MEDIA_LIMIT = MsgHelpers::MEDIA_CAPTION_LIMIT

    def visible_size(text) = text.gsub(/\\(.)/m, '\1').size

    def prepare(text, parse_mode:)
      text = text.to_s
      return text if visible_size(text) <= MEDIA_LIMIT

      yield text if block_given?
      truncate(text)
    end

    def truncate(text, limit = MEDIA_LIMIT)
      suffix = Utils::Url.trailing_display_urls(text)
      return truncate_markdown(text, limit) unless suffix && suffix.size < limit

      body = text.to_s.delete_suffix(suffix).rstrip
      [truncate_markdown(body, limit - suffix.size), suffix].join
    end

    def truncate_markdown(text, limit)
      caption = text.to_s.first(limit)
      caption = caption[0...-1] if caption.end_with?('\\')
      return caption unless caption.scan(/(?<!\\)_/).size.odd?

      caption.size < limit ? "#{caption}_" : "#{caption[0...-1]}_"
    end
  end
end
