require_relative 'markdown'

class TDBot
  module Helpers

    include MsgHelpers

    TD.configure do |config|
      config.client.api_id   = ENV['TDLIB_API_ID']
      config.client.api_hash = ENV['TDLIB_API_HASH']
      config.client.database_directory = "#{Dir.pwd}/.tdlib/db"
      config.client.files_directory    = "#{Dir.pwd}/.tdlib/files"
    end
    TD::Api.set_log_verbosity_level 0

    extend ActiveSupport::Concern
    included do
      class_attribute :td, :client
      self.client = self.td = TD::Client.new timeout: 1.minute

      # Map [chat_id, temporary_id] -> final_id
      @@msg_id_map = {}

      DUMMY_THUMB = TD::Types::InputThumbnail.new(
        thumbnail: TD::Types::InputFile::Remote.new(id: '0'),
        width: 0, height: 0
      )

      client.on TD::Types::Update::MessageSendSucceeded do |u|
        @@msg_id_map[[u.message.chat_id, u.old_message_id]] = u.message.id
      end
    end

    def listen
      client.on TD::Types::Update::NewMessage do |update|
        orig_msg = update.message
        text = case orig_msg.content
        when TD::Types::MessageContent::Text
          STDERR.puts orig_msg.content.text
          orig_msg.content.text&.text
        when TD::Types::MessageContent::Photo,
             TD::Types::MessageContent::Video,
             TD::Types::MessageContent::Audio,
             TD::Types::MessageContent::Document
          orig_msg.content.caption&.text
        else
          nil
        end
        msg = SymMash.new(
          orig_msg.to_h.merge(
            chat: {id: orig_msg.chat_id},
            from: {id: orig_msg.sender_id.user_id},
            text: text,
          )
        )
        case orig_msg.content
        when TD::Types::MessageContent::Audio
          msg[:audio]    = orig_msg.content.audio
        when TD::Types::MessageContent::Video
          msg[:video]    = orig_msg.content.video
        when TD::Types::MessageContent::Document
          msg[:document] = orig_msg.content.document
        end
        # Ignore messages sent by the bot itself (identified by user id)
        @self_id ||= td.get_me.value.id
        if (sid = msg.sender_id)&.respond_to?(:user_id)
          next if sid.user_id == @self_id
        end

        # Mark original message as read immediately
        mark_read msg

        yield msg
      end
    end

    def parse_markdown(text)
      TDBot::Markdown.parse(td, text)
    end

    def send_message msg, text, type: 'message', chat_id: msg.chat_id, **params
      caption_ft = parse_markdown(text)

      # Build an InputThumbnail only if a :thumb param is provided; otherwise keep it nil.
      ithumb = if (tp = params[:thumb])
        tp_path = tp.respond_to?(:path) ? tp.path : tp.to_s
        TD::Types::InputThumbnail.new thumbnail: TD::Types::InputFile::Local.new(path: tp_path), width: 0, height: 0
      end

      content = if (file = params[:video] || params[:audio] || params[:document])
        path       = file.respond_to?(:path) ? file.path : file.to_s
        input_file = TD::Types::InputFile::Local.new path: path

        if params[:video]
          width     = (params[:width]  || 0).to_i
          height    = (params[:height] || 0).to_i
          duration  = (params[:duration] || 0).to_i
          video_args = {
            video:       input_file,
            duration:    duration,
            width:       width,
            height:      height,
            caption:     caption_ft,
            has_spoiler: false,
            supports_streaming:       true,
            show_caption_above_media: false,
            added_sticker_file_ids:   [], # required
          }
          video_args[:thumbnail] = ithumb if ithumb
          TD::Types::InputMessageContent::Video.new video_args
        elsif params[:audio]
          audio_args = {
            audio:     input_file,
            duration:  params[:duration].to_i,
            title:     params[:title].to_s,
            performer: params[:performer].to_s,
            caption:   caption_ft,
            album_cover_thumbnail: ithumb || DUMMY_THUMB,
          }
          TD::Types::InputMessageContent::Audio.new audio_args
        elsif params[:document]
          doc_args = {
            document: input_file,
            disable_content_type_detection: false,
            caption: caption_ft,
            thumbnail: ithumb || DUMMY_THUMB,
          }
          TD::Types::InputMessageContent::Document.new doc_args
        end
      else
        TD::Types::InputMessageContent::Text.new clear_draft: false, text: caption_ft
      end

      reply_id = params.delete(:reply_to_message_id) || (msg[:message_id] || msg[:id]).to_i

      # Build modern reply_to object if a reply target exists; otherwise pass nil.
      reply_to_obj = if reply_id.positive?
        empty_quote = TD::Types::InputTextQuote.new(
          text: TD::Types::FormattedText.new(text: '', entities: []),
          position: 0,
        )
        TD::Types::InputMessageReplyTo::Message.new(message_id: reply_id, quote: empty_quote)
      end

      rmsg = client.send_message(
        chat_id:               chat_id,
        message_thread_id:     0,
        reply_to:              reply_to_obj,
        options:               nil,
        reply_markup:          nil,
        input_message_content: content,
      ).value!

      # If we just uploaded a media file, wait until TDLib confirms the message is sent successfully.
      if file
        key = [chat_id, rmsg.id]
        start = Time.now
        sleep 0.1 until @@msg_id_map.key?(key) || Time.now - start > 300 # max 5 minutes
      end

      SymMash.new message_id: rmsg.id, text: text.to_s
    end

    def read_state
      client.on TD::Types::Update::AuthorizationState do |update|
        @state = case update.authorization_state
          when TD::Types::AuthorizationState::WaitPhoneNumber
            :wait_phone_number
          when TD::Types::AuthorizationState::WaitCode
            :wait_code
          when TD::Types::AuthorizationState::WaitPassword
            :wait_password
          when TD::Types::AuthorizationState::Ready
            :ready
          else
            nil
          end
      end
    end

    def get_supergroup_members supergroup_id: ENV['REPORT_SUPERGROUP_ID']&.to_i, chat_id: ENV['REPORT_CHAT_ID']&.to_i, limit: 200
      supergroup_id ||= td.get_chat(chat_id: chat_id).value.type.supergroup_id

      total = td.get_supergroup_members(supergroup_id: supergroup_id, filter: nil, offset: 0, limit: 1).value.total_count
      pages = (total.to_f / limit).ceil
      pages.times.flat_map do |p|
        td.get_supergroup_members(
          supergroup_id: supergroup_id, filter: nil, offset: p*limit, limit: limit,
        ).value.members
      end
    end

    def delete_message msg, id, wait: 30
      Thread.new do
        sleep wait if wait
      ensure
        client.delete_messages chat_id: msg.chat_id, message_ids: [id], revoke: true
      end
    rescue
      # ignore
    end

    def edit_message msg, id, text:, **_
      formatted = TD::Types::FormattedText.new text: text, entities: []
      content   = TD::Types::InputMessageContent::Text.new clear_draft: false, text: formatted

      # Resolve final message id if the one we have is temporary
      id2 = @@msg_id_map[[msg.chat_id, id]] || id
      start = Time.now
      sleep 0.1 until id2.positive? || Time.now - start > 3
      id2 = @@msg_id_map[[msg.chat_id, id]] || id

      client.edit_message_text(chat_id: msg.chat_id, message_id: id2, reply_markup: nil, input_message_content: content).value!
    rescue => e
      STDERR.puts "edit_error: #{e.class}: #{e.message}"
    end

    def mark_read msg
      client.view_messages chat_id: msg.chat_id, message_ids: [msg.id], source: nil, force_read: true
    rescue => e
      STDERR.puts "mark_read_error: #{e.class}: #{e.message}"
    end

    # Workaround for schema mismatch: older tdlib versions may omit some required fields.
    begin
      module TD::Types
        class User < Base
          class << self
            alias_method :__orig_new, :new unless method_defined?(:__orig_new)

            def new(hash)
              h = hash.dup
              # Ensure required boolean flags exist to avoid Dry::Struct errors
              %w[is_verified is_premium is_support is_scam is_fake has_active_stories has_unread_active_stories restricts_new_chats have_access added_to_attachment_menu].each do |k|
                h[k] = false unless h.key?(k)
              end
              # numeric defaults that may be absent
              %w[accent_color_id background_custom_emoji_id profile_accent_color_id profile_background_custom_emoji_id].each do |k|
                h[k] = 0 unless h.key?(k)
              end
              __orig_new(h)
            end
          end
        end
      end
    rescue NameError
      # TD::Types::User not yet loaded; ignore
    end

    # Define stub classes for unknown update types so TD::Types.wrap can succeed
    module TD::Types
      class EmojiStatusTypeCustomEmoji < EmojiStatus; end unless const_defined?(:EmojiStatusTypeCustomEmoji)
      class PaidReactionTypeRegular < Base; end unless const_defined?(:PaidReactionTypeRegular)
      class ChatFolderName < Base; end unless const_defined?(:ChatFolderName)
    end

    begin
      TD::Types::LOOKUP_TABLE['emojiStatusTypeCustomEmoji'] ||= 'EmojiStatusTypeCustomEmoji'
      TD::Types::LOOKUP_TABLE['paidReactionTypeRegular']    ||= 'PaidReactionTypeRegular'
      TD::Types::LOOKUP_TABLE['chatFolderName']             ||= 'ChatFolderName'
    rescue
      # ignore
    end

    # Provide the same .text helper as telegram-bot-ruby for easier interoperability
    module TD::Types
      class Message < Base
        def text
          case content
          when MessageContent::Text
            content.text&.text
          when MessageContent::Photo, MessageContent::Video, MessageContent::Audio, MessageContent::Document
            content.caption&.text
          else
            nil
          end
        end unless method_defined? :text

        # Ensure optional flags absent in older TDLib versions exist
        class << self
          alias_method :__orig_new_msg, :new unless method_defined?(:__orig_new_msg)
          def new(hash)
            h = hash.dup
            h[:is_topic_message] = false unless h.key?(:is_topic_message) || h.key?('is_topic_message')
            h[:saved_messages_topic_id] ||= 0
            __orig_new_msg(h)
          end
        end
      end
    end

    # Provide defaults for new boolean/int flags missing in older TDLib builds so
    # tdlib-ruby structs never crash. This is version-agnostic: if the flag is
    # already present we keep it, otherwise we supply a sane default.
    module TD::Types
      class MessageSelfDestructType < Base; end unless const_defined?(:MessageSelfDestructType)

      %i[ScopeNotificationSettings ChatNotificationSettings].each do |klass|
        next if const_defined?(klass)
      end

      # Patch ScopeNotificationSettings and ChatNotificationSettings to tolerate
      # missing story-related flags in older tdlib builds.
      {
        ScopeNotificationSettings: %i[show_story_sender use_default_show_story_sender],
        ChatNotificationSettings:  %i[show_story_sender use_default_show_story_sender],
      }.each do |kls, flags|
        base = const_get(kls) rescue next
        flag_list = flags
        class << base
          alias_method :__orig_new_notif, :new unless method_defined?(:__orig_new_notif)
          define_method :new do |hash|
            h = hash.dup
            flag_list.each { |f| h[f] = false unless h.key?(f) || h.key?(f.to_s) }
            __orig_new_notif(h)
          end
        end
      end

      # Make self_destruct_type optional for InputMessageContent::Video to support older TDLib versions.
      class InputMessageContent::Video < InputMessageContent
        class << self
          alias_method :__orig_new_video, :new unless method_defined?(:__orig_new_video)

          def new(hash)
            h = hash.dup
            h[:self_destruct_type] ||= TD::Types::MessageSelfDestructType::Timer.new(self_destruct_time: 0)
            __orig_new_video(h)
          end
        end

        # Remove self_destruct_type from the hash sent to TDLib to stay compatible with old versions
        def to_hash
          h = super
          h.delete(:self_destruct_type)
          h.delete('self_destruct_type')
          h
        end
        alias_method :to_h, :to_hash
      end
    end

    # Escape only the non-format Markdown characters required by Telegram Markdown V2 while keeping * _ for styling
    def me(text)
      return text unless text
      MsgHelpers::MARKDOWN_NON_FORMAT.each { |c| text = text.gsub(c, "\\#{c}") }
      text
    end
    alias_method :mnfe, :me
    def mfe(text)
      return text unless text
      MsgHelpers::MARKDOWN_FORMAT.each { |c| text = text.gsub(c, "\\#{c}") }
      text
    end

    # Download any Telegram file (audio, video, document) via TDLib and return
    # the local filesystem path.
    def download_file(info, dir: nil)
      td = self.td

      file_id, remote_id, file_name = case info
      when TD::Types::Document
        [info.document.id, info.document.remote.id, info.file_name]
      when TD::Types::MessageDocument
        [info.document.id, info.document.remote.id, info.file_name]
      when TD::Types::Audio
        [info.audio.id,    info.audio.remote.id,    info.file_name]
      when TD::Types::Video
        [info.video.id,    info.video.remote.id,    info.file_name]
      else
        id = info.respond_to?(:id) ? info.id : nil
        [id, nil, info.respond_to?(:file_name) ? info.file_name : nil]
      end

      raise 'Unsupported info type for download' unless file_id || remote_id

      if file_id && file_id.nonzero?
        td.download_file(file_id: file_id, priority: 1, offset: 0, limit: 0, synchronous: true)
        file_info = td.get_file(file_id: file_id).value
      elsif remote_id && !remote_id.empty?
        # Attempt to register remote file to obtain a valid file_id
        rf = td.search_public_file(remote_id: remote_id).value rescue nil
        fid = rf&.id
        raise 'No valid file identifier' unless fid && fid.nonzero?
        td.download_file(file_id: fid, priority: 1, offset: 0, limit: 0, synchronous: true)
        file_info = td.get_file(file_id: fid).value
      else
        raise 'Unsupported info type for download'
      end
      file_info.local.path
    end

  end
end
