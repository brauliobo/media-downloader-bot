module TDBot
  class PostEditor
    include TD::Logging
    include MediaContent
    include Summaries
    include UploadWait
    include ChatOperations

    def initialize(bot)
      @bot = bot
    end

    def edit_generated_message(chat_id:, message_id:, text: nil, type: nil, parse_mode: 'MarkdownV2', **params)
      media_type = (type || params[:type]).to_s
      return edit_generated_text(chat_id, message_id, text, parse_mode) if media_type.in?(%w[message text])

      content = generated_message_content(media_type, text, parse_mode, params)
      bot.with_rate_limit('edit_generated_message') do
        bot.send(:throttle!)
        result = td.edit_message_media(
          chat_id:               chat_id,
          message_id:            message_id,
          reply_markup:          nil,
          input_message_content: content
        ).value!
        dlog "[TD_EDIT_GENERATED] chat=#{chat_id} id=#{message_id} type=#{media_type} result=#{result&.class}"
        message   = wait_uploaded_message(chat_id, result&.id || message_id)
        remote_id = message_remote_file_id(message)
        raise "edited #{media_type} has no remote file id" if remote_id.to_s.empty?

        {message_id: message.id, remote_id: remote_id}
      end
    end

    def upload_generated_media(chat_id:, text: nil, type:, parse_mode: 'MarkdownV2', **params)
      media_type = type.to_s
      forum_topic_id = params.delete(:forum_topic_id).to_i
      content    = generated_message_content(media_type, text, parse_mode, params)
      bot.send(:throttle!)
      sent       = send_message_content(chat_id, forum_topic_id, content)

      message   = wait_uploaded_message(chat_id, sent.id)
      remote_id = message_remote_file_id(message)
      raise "uploaded #{media_type} has no remote file id" if remote_id.to_s.empty?

      { message_id: message.id, remote_id: remote_id }
    end

    def ensure_forum_topic(chat_id:, name:)
      topics = td.get_forum_topics(
        chat_id: chat_id, query: name, offset_date: 0, offset_message_id: 0,
        offset_forum_topic_id: 0, limit: 100
      ).value!(30)
      info = Array(topics&.topics).map(&:info).find { |topic| topic.name == name }
      info ||= td.create_forum_topic(chat_id: chat_id, name: name, is_name_implicit: false, icon: nil).value!(30)
      { forum_topic_id: info.forum_topic_id, name: info.name }
    end

    def find_chats(query, limit: 20, public: false)
      ids = []
      username = ChatIdentifier.public_username(query)

      if public && username
        chat = ChatIdentifier.resolve(td, username)
        ids << chat.id if chat
      end

      found = td.search_chats(query: query.to_s, type_filter: nil, limit: limit).value(15)
      ids.concat Array(found&.chat_ids)

      if public
        found = td.search_public_chats(query: query.to_s, type_filter: nil).value(30)
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

    def send_message_content(chat_id, forum_topic_id, content)
      content = td_payload(content)
      td.send_message(
        chat_id:               chat_id,
        topic_id:              message_topic(forum_topic_id),
        reply_to:              nil,
        options:               nil,
        reply_markup:          nil,
        input_message_content: content
      ).value!
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
  end
end
