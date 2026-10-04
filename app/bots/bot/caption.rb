module Bot
  module Caption
    module_function

    MEDIA_LIMIT = MsgHelpers::MEDIA_CAPTION_LIMIT

    def normalize(text, parse_mode:)
      return text.to_s unless parse_mode.to_s == 'MarkdownV2'

      MsgHelpers::MARKDOWN_NON_FORMAT.reduce(text.to_s) { |caption, char| caption.gsub("\\#{char}", char) }
    end

    def prepare(text, parse_mode:)
      text = normalize(text, parse_mode: parse_mode)
      return text if text.size <= MEDIA_LIMIT

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
