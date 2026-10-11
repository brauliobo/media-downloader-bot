module Bot
  # The text of a TDLib message content: its own text, or the caption of a media message.
  module FormattedText
    module_function

    def of(content)
      formatted = content.try(:text) || content.try(:caption)
      formatted.try(:text) || formatted.to_s
    end
  end
end
