require 'fileutils'
require 'rack/mime'

module Downloaders
  class Telegram < Base

    MIME_EXT = {
      'image/jpeg' => '.jpg',
      'image/jpg'  => '.jpg',
      'image/png'  => '.png',
      'image/webp' => '.webp',
      'image/gif'  => '.gif',
      'video/mp4'  => '.mp4',
      'video/webm' => '.webm',
      'audio/ogg'  => '.ogg',
      'audio/mpeg' => '.mp3',
      'audio/mp4'  => '.m4a',
      'text/plain' => '.txt',
    }.freeze
    KIND_EXT = {photo: '.jpg', video: '.mp4', audio: '.ogg', document: '.bin'}.freeze
    ZIPPER_KINDS = %i[video audio].freeze

    def self.supports?(ctx)
      Link.parse(ctx.url).present?
    end

    def download
      link = Link.parse(url)
      raise 'Invalid t.me link' unless link
      raise 'Private Telegram links are restricted to the administrator' if link.private? && !admin?

      if td && defined?(TD::Types)
        download_tdlib(link)
      else
        raise 'Private Telegram links require the Telegram client' if link.private?

        download_embed(link)
      end
    end

    def download_one(_input, **_kwargs) = true

    private

    def download_embed(link)
      post = Embed.parse(Utils::HTTP.get_public(link.embed_url))
      raise post.error if post.error

      files = post.items.map.with_index { |item, index| fetch_remote(item, link, index) }
      files << text_file(post.text, link) if files.empty? && post.text.present?
      raise 'Telegram post has no downloadable media' if files.empty?

      build_result(files, link, text: post.text, author: post.author)
    end

    def download_tdlib(link)
      raise 'Telegram client is unavailable' unless defined?(TD::Types) && td

      chat_id, message_id = td_ids(link)
      message = td.get_message(chat_id: chat_id, message_id: message_id).value
      files   = Array.wrap(td_file(message.content)).compact
      text    = td_text(message.content)
      files   << text_file(text, link) if files.empty? && text.present?
      raise 'Unsupported t.me message type' if files.empty?

      build_result(files, link, text: text, author: td_author(message))
    end

    def td_ids(link)
      if link.slug
        chat = td.search_public_chat(username: link.slug).value
        [chat.id, link.message_id]
      else
        [link.td_chat_id, link.message_id]
      end
    end

    def td_file(content)
      file, name, kind = td_file_info(content)
      return unless file

      td.download_file(file_id: file.id, priority: 1, synchronous: true)
      path = td.get_file(file_id: file.id).value.local.path
      media(kind, path, name || File.basename(path))
    end

    def td_file_info(content)
      case content
      when TD::Types::MessageContent::Document
        [content.document.document, content.document.file_name, :document]
      when TD::Types::MessageContent::Audio
        [content.audio.audio, content.audio.file_name, :audio]
      when TD::Types::MessageContent::Video
        [content.video.video, content.video.file_name, :video]
      when TD::Types::MessageContent::Photo
        size = content.photo.sizes.max_by { |entry| entry.width.to_i * entry.height.to_i }
        [size&.photo, 'photo.jpg', :photo]
      when TD::Types::MessageContent::Animation
        [content.animation.animation, content.animation.file_name.presence || 'animation.mp4', :video]
      when TD::Types::MessageContent::VoiceNote
        [content.voice_note.voice, 'voice.ogg', :audio]
      when TD::Types::MessageContent::VideoNote
        [content.video_note.video, 'video_note.mp4', :video]
      when TD::Types::MessageContent::Text
        nil
      else
        raise 'Unsupported t.me message type'
      end
    end

    def td_text(content)
      formatted = if content.respond_to?(:text)
        content.text
      elsif content.respond_to?(:caption)
        content.caption
      end
      (formatted.respond_to?(:text) ? formatted.text : formatted.to_s).presence
    end

    def td_author(message)
      message.author_signature.presence
    end

    def fetch_remote(item, link, index)
      ext  = KIND_EXT.fetch(item.kind, '.bin')
      path = File.join(tmp, "telegram-#{link.message_id}-#{index + 1}#{ext}")
      type = Utils::HTTP.download_public(item.url, path)
      ext  = extension_for(type, item.kind)
      path = rename_extension(path, ext)
      media(item.kind, path, File.basename(path))
    end

    def text_file(text, link)
      path = File.join(tmp, "telegram-#{link.message_id}.txt")
      Utils::Safety.write_exclusive(path, text)
      media(:document, path, File.basename(path), 'text/plain')
    end

    def media(kind, path, name, mime = nil)
      mime ||= Rack::Mime.mime_type(File.extname(path).downcase) || 'application/octet-stream'
      {kind: kind, path: path, name: name, mime: mime}
    end

    def build_result(files, link, text:, author:)
      info = SymMash.new(
        title:      text.presence || files.first[:name],
        uploader:   author,
        display_id: link.display_id,
      )
      popts = opts.deep_dup.tap { |o| o.caption ||= 1 }
      source = link.canonical_url

      if zipper_input?(files)
        file = files.first
        return SymMash.new(fn_in: file[:path], url: source, opts: popts, info: info)
      end

      uploads = files.map.with_index { |file, index| upload_from(file, index, info, popts, source) }
      SymMash.new(url: source, opts: popts, info: info, uploads: uploads)
    end

    def zipper_input?(files)
      files.one? && ZIPPER_KINDS.include?(files.first[:kind])
    end

    def upload_from(file, index, info, popts, source)
      type = Utils::MimeTypes.type_for_mime(file[:mime])
      SymMash.new(
        fn_out: file[:path],
        type:   SymMash.new(name: type),
        mime:   file[:mime],
        opts:   popts.deep_dup,
        url:    source,
        info:   info.merge(title: info.title.presence || file[:name], display_id: "#{info.display_id}-#{index + 1}")
      )
    end

    def extension_for(content_type, kind)
      mime = content_type.to_s.split(';').first.to_s.strip.downcase
      MIME_EXT[mime] || KIND_EXT.fetch(kind, '.bin')
    end

    def rename_extension(path, ext)
      return path if File.extname(path).downcase == ext

      renamed = path.sub(/#{Regexp.escape(File.extname(path))}\z/, ext)
      File.rename(path, renamed)
      renamed
    end

    def td
      bot = msg&.bot
      bot.td if bot.respond_to?(:td)
    end

    def admin?
      msg && Bot::MsgHelpers.from_admin?(msg)
    end
  end
end
