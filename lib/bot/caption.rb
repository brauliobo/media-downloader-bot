require_relative 'msg_helpers'

module Bot
  module Caption
    module_function

    def normalize(text, parse_mode:)
      return text.to_s unless parse_mode.to_s == 'MarkdownV2'

      MsgHelpers::MARKDOWN_NON_FORMAT.reduce(text.to_s) { |caption, char| caption.gsub("\\#{char}", char) }
    end
  end
end
