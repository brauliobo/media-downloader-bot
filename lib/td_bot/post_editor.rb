module TDBot
  class PostEditor
    include TD::Logging

    UPLOAD_TIMEOUT = 1_800

    def initialize(bot)
      @bot = bot
    end

    def edit_generated_message(chat_id:, message_id:, text: nil, type: nil, parse_mode: 'MarkdownV2', **params)
      media_type = (type || params[:type]).to_s
      return edit_generated_text(chat_id, message_id, text, parse_mode) if media_type.in?(%w[message text])

      content = generated_message_content(media_type, text, parse_mode, params)
      bot.send(:td_with_rate_limit, 'edit_generated_message') do
        result = td.edit_message_media(
          chat_id:               chat_id,
          message_id:            message_id,
          reply_markup:          nil,
          input_message_content: content
        ).value!(120)
        dlog "[TD_EDIT_GENERATED] chat=#{chat_id} id=#{message_id} type=#{media_type} result=#{result&.class}"
        result
      end
    end

    def upload_generated_media(chat_id:, text: nil, type:, parse_mode: 'MarkdownV2', **params)
      media_type = type.to_s
      timeout    = params[:timeout].to_i.nonzero? || UPLOAD_TIMEOUT
      content    = generated_message_content(media_type, text, parse_mode, params)
      sent       = send_message_content(chat_id, content, timeout)

      message   = wait_uploaded_message(chat_id, sent.id, timeout: timeout)
      remote_id = message_remote_file_id(message)
      raise "uploaded #{media_type} has no remote file id" if remote_id.to_s.empty?

      { message_id: message.id, remote_id: remote_id }
    end

    def find_chats(query, limit: 20, public: false)
      ids = []
      username = ChatIdentifier.public_username(query)

      if public && username
        chat = ChatIdentifier.resolve(td, username)
        ids << chat.id if chat
      end

      found = td.search_chats(query: query.to_s, limit: limit).value(15)
      ids.concat Array(found&.chat_ids)

      if public
        found = td.search_public_chats(query: query.to_s).value(30)
        ids.concat Array(found&.chat_ids)
      end

      ids.uniq.first(limit).map { |id| chat_summary(td.get_chat(chat_id: id).value(15)) }
    rescue => e
      dlog "[TD_FIND_CHATS_ERROR] #{e.class}: #{e.message}"
      []
    end

    def resolve_chat_identifier(identifier)
      chat_summary(ChatIdentifier.resolve(td, identifier))
    end

    def chat_messages(chat_id:, limit: 20, query: nil, filter: nil, from_message_id: 0)
      result = if query.to_s.empty? && filter.to_s.empty?
        td.get_chat_history(
          chat_id:         chat_id,
          from_message_id: from_message_id,
          offset:          0,
          limit:           limit,
          only_local:      false
        ).value(20)
      else
        td.search_chat_messages(
          chat_id:                 chat_id,
          query:                   query.to_s,
          sender_id:               nil,
          from_message_id:         from_message_id,
          offset:                  0,
          limit:                   limit,
          filter:                  search_messages_filter(filter),
          message_thread_id:       0,
          saved_messages_topic_id: 0
        ).value(20)
      end

      Array(result&.messages).map { |message| message_summary(message) }
    end

    def chat_message(chat_id:, message_id:)
      message = td.get_message(chat_id: chat_id, message_id: message_id).value(20)
      message_summary(message) if message
    end

    private

    attr_reader :bot

    def td
      bot.td
    end

    def message_sender
      bot.message_sender
    end

    def edit_generated_text(chat_id, message_id, text, parse_mode)
      msg = SymMash.new(chat: { id: chat_id })
      bot.edit_message(msg, message_id, text: text.to_s, parse_mode: parse_mode, force: true)
    end

    def send_message_content(chat_id, content, timeout)
      content = td_payload(content)
      td.send_message(
        chat_id:               chat_id,
        message_thread_id:     0,
        reply_to:              nil,
        options:               nil,
        reply_markup:          nil,
        input_message_content: content
      ).value!(timeout)
    end

    def td_payload(value)
      case value
      when TD::Types::Base
        td_payload(value.to_h)
      when Hash
        value.each_with_object({}) do |(key, val), obj|
          payload = td_payload(val)
          obj[key.to_s] = payload unless payload.nil?
        end
      when Array
        value.map { |item| td_payload(item) }
      else
        value
      end
    end

    def generated_message_content(media_type, text, parse_mode, params)
      caption    = td_payload(message_sender.send(:parse_markdown_text, text.to_s, parse_mode))
      input_file = generated_input_file(media_type, params)
      thumbnail  = generated_thumbnail(params)

      case media_type
      when 'audio'
        {
          '@type'   => 'inputMessageAudio',
          'audio'   => {
            '@type'                 => 'inputAudio',
            'audio'                 => input_file,
            'album_cover_thumbnail' => thumbnail,
            'duration'              => params[:duration].to_i,
            'title'                 => params[:title].to_s,
            'performer'             => params[:performer].to_s
          },
          'caption' => caption
        }
      when 'video'
        {
          '@type'                    => 'inputMessageVideo',
          'video'                    => {
            '@type'                  => 'inputVideo',
            'video'                  => input_file,
            'thumbnail'              => thumbnail,
            'cover'                  => nil,
            'start_timestamp'        => 0,
            'added_sticker_file_ids' => [],
            'duration'               => params[:duration].to_i,
            'width'                  => params[:width].to_i,
            'height'                 => params[:height].to_i,
            'supports_streaming'     => params.fetch(:supports_streaming, false)
          },
          'caption'                  => caption,
          'show_caption_above_media' => false,
          'self_destruct_type'       => nil,
          'has_spoiler'              => false
        }
      when 'document'
        {
          '@type'    => 'inputMessageDocument',
          'document' => {
            '@type'                          => 'inputDocument',
            'document'                       => input_file,
            'thumbnail'                      => thumbnail,
            'disable_content_type_detection' => false
          },
          'caption'  => caption
        }
      else
        raise ArgumentError, "unsupported generated message type: #{media_type.inspect}"
      end
    end

    def generated_input_file(media_type, params)
      return { '@type' => 'inputFileRemote', 'id' => params[:remote_id].to_s } if params[:remote_id].present?

      path = generated_file_path(media_type, params)
      path = message_sender.file_manager.copy_to_safe_location(path) unless params[:copy] == false
      { '@type' => 'inputFileLocal', 'path' => path }
    end

    def generated_file_path(media_type, params)
      path = params[:file_path] || params[:file] || params[:"#{media_type}_path"] || params[media_type.to_sym]
      raise ArgumentError, "missing generated #{media_type} file path" if path.to_s.empty?
      raise ArgumentError, "generated file does not exist: #{path}" unless File.exist?(path.to_s)

      path.to_s
    end

    def generated_thumbnail(params)
      path = thumbnail_path(params)
      return unless path && File.exist?(path.to_s)

      safe_path = message_sender.file_manager.copy_to_safe_location(path.to_s)
      {
        '@type'     => 'inputThumbnail',
        'thumbnail' => { '@type' => 'inputFileLocal', 'path' => safe_path },
        'width'     => 0,
        'height'    => 0
      }
    end

    def thumbnail_path(params)
      params.values_at(:thumb_path, :thumbnail_path, :thumbnail, :thumb).compact.first
    end

    def chat_summary(chat)
      { id: chat.id, title: chat.title, type: chat.type.class.name.split('::').last }
    end

    def message_summary(message)
      content = message.content
      {
        id:                  message.id,
        chat_id:             message.chat_id,
        date:                message.date,
        type:                content.class.name.split('::').last,
        text:                message_text(content),
        media:               message_media(content),
        reply_to_message_id: message_reply_to_id(message),
        can_edit:            message.respond_to?(:can_be_edited) ? message.can_be_edited : nil,
        sender_id:           message.sender_id.respond_to?(:user_id) ? message.sender_id.user_id : nil
      }
    end

    def message_reply_to_id(message)
      reply_to = message.reply_to if message.respond_to?(:reply_to)
      reply_to.message_id if reply_to.respond_to?(:message_id)
    end

    def message_text(content)
      formatted = if content.respond_to?(:text)
        content.text
      elsif content.respond_to?(:caption)
        content.caption
      end
      formatted.respond_to?(:text) ? formatted.text : formatted.to_s
    end

    def message_media(content)
      case content
      when TD::Types::MessageContent::Document
        file = content.document.document
        media_summary('document', file, content.document.file_name, content.document.mime_type)
      when TD::Types::MessageContent::Audio
        file = content.audio.audio
        media_summary('audio', file, content.audio.file_name, content.audio.mime_type, duration: content.audio.duration)
      when TD::Types::MessageContent::Video
        file = content.video.video
        media_summary('video', file, content.video.file_name, content.video.mime_type, duration: content.video.duration)
      end
    end

    def media_summary(kind, file, file_name, mime_type, duration: nil)
      {
        kind:      kind,
        file_id:   file.id,
        remote_id: file.remote&.id,
        file_name: file_name,
        mime_type: mime_type,
        duration:  duration
      }.compact
    end

    def search_messages_filter(filter)
      case filter.to_s
      when '', 'all' then nil
      when 'audio'  then TD::Types::SearchMessagesFilter::Audio.new
      when 'video'  then TD::Types::SearchMessagesFilter::Video.new
      when 'document', 'doc' then TD::Types::SearchMessagesFilter::Document.new
      else
        raise ArgumentError, "unsupported message filter: #{filter.inspect}"
      end
    end

    def wait_uploaded_message(chat_id, message_id, timeout:)
      deadline = Time.now + timeout

      loop do
        actual_id = message_sender.message_id_map[message_id] || message_id
        message   = td.get_message(chat_id: chat_id, message_id: actual_id).value(30) rescue nil
        remote_id = message_remote_file_id(message) if message
        return message if remote_id.present? && message_uploaded?(message)

        raise "timed out waiting for uploaded media message #{message_id}" if Time.now >= deadline
        sleep 2
      end
    end

    def message_uploaded?(message)
      file = message_file(message)
      file.nil? || file.remote&.is_uploading_completed
    end

    def message_file(message)
      content = message&.content
      case content
      when TD::Types::MessageContent::Audio
        content.audio.audio
      when TD::Types::MessageContent::Video
        content.video.video
      when TD::Types::MessageContent::Document
        content.document.document
      end
    end

    def message_remote_file_id(message)
      message_file(message)&.remote&.id
    end
  end
end
