class Worker
  # What is sent with a processed item: title, uploader, description, source link and hashtags,
  # cut to fit the limit and translated into the language asked for.
  class Caption
    def initialize(opts = nil)
      @opts = opts
    end

    def render(i, max: nil, info: i.info)
      caption_opts = i.opts || @opts || SymMash.new
      return '' if caption_opts.nocaption

      return build(i, info: info) unless max

      title = info.title.to_s
      best  = nil
      low   = 0
      high  = title.size

      while low <= high
        mid  = (low + high) / 2
        text = build(i, title: title.first(mid), info: info)
        if text.size <= max
          best = text
          low  = mid + 1
        else
          high = mid - 1
        end
      end

      best || build(i, title: '', info: info)
    end

    def translate_info(info, opts)
      target = Processors::LanguageOpts.from(opts)
      return info unless target

      caption_info = (opts.clang || opts.dub_lang) ? info.deep_dup : info
      [:title, (:description if opts.description)].compact.each do |field|
        caption_info[field] = translate_text(info[field], from: info.language, to: target) if info[field].present?
      end
      caption_info
    end

    def translate_text(text, from:, to:)
      urls = text.to_s[%r{(?:\s+https?://\S+)+\s*\z}]
      body = urls ? text.to_s.delete_suffix(urls).strip : text.to_s
      [translate_body(body, from: from, to: to), urls.to_s.strip.presence].compact.join(' ')
    end

    private

    def build(i, title: nil, info: i.info)
      caption_opts = i.opts || @opts || SymMash.new
      text = ''
      if caption_opts.caption || Utils::MimeTypes.telegram_type(i) == :video
        title_text = (title || info.title).to_s
        text  = italic(title_text) if title_text.present?
        text << "\n" if text.present? && info.uploader
        text << Bot::MsgHelpers.me(info.uploader) if info.uploader
      end
      if caption_opts.description and info.description.strip.presence
        text << "\n\n" if text.present?
        text << italic(info.description.strip)
      end
      if (source_url = Utils::Url.display(i.url))
        text << "\n\n" if text.present?
        text << Bot::MsgHelpers.me(source_url)
      end
      if info.hashtags.present?
        text << "\n\n" if text.present?
        text << Bot::MsgHelpers.me(info.hashtags)
      end
      text
    end

    def italic(text)
      text.to_s.split(/(\n+)/).map do |part|
        part.match?(/\A\n+\z/) || part.empty? ? part : "_#{Bot::MsgHelpers.me(part)}_"
      end.join
    end

    def translate_body(body, from:, to:)
      parts = body.to_s.split(/(\n{2,})/)
      parts.map do |part|
        if part.blank? || part.match?(/\A\n+\z/)
          part
        else
          translate_segment(part, from: from, to: to)
        end
      end.join
    end

    def translate_segment(text, from:, to:)
      chunks = text.to_s.split(/(?<=[.!?])\s+/)
      return Translator.translate(text, from: from, to: to) if chunks.one?

      Array(Translator.translate(chunks, from: from, to: to)).join(' ')
    end
  end
end
