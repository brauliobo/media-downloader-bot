class Worker
  # The captions sent with processed items, alone or sharing an album caption.
  module Captions
    ALBUM_CAPTION_SEPARATOR = "\n\n".freeze

    def caption_limit
      service.try(:max_caption) || Bot::MsgHelpers::MEDIA_CAPTION_LIMIT
    end

    def caption_for(input, max: caption_limit)
      caption = Caption.new(opts)
      caption.render(input, max: max, info: caption.translate_info(input.info, input.opts))
    end

    # One caption per item (title, source link, ...) sharing the album caption limit.
    def album_caption(inputs)
      budget = (caption_limit - ALBUM_CAPTION_SEPARATOR.size * (inputs.size - 1)) / inputs.size
      inputs.map { |input| caption_for(input, max: budget) }.reject(&:blank?).join(ALBUM_CAPTION_SEPARATOR)
    end
  end
end
