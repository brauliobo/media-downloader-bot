require_relative 'markdown'
require_relative 'compat'

class TDBot
  def self.dlog(msg); puts msg if ENV['TDLOG'].to_i > 0; end
  module Helpers

    include MsgHelpers

    def dlog(msg); TDBot.dlog(msg); end

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

      # Track unread counters and connection state for visibility into pending msgs
      client.on TD::Types::Update::UnreadMessageCount do |u|
        dlog "[UNREAD] messages=#{u.unread_count} unmuted=#{u.unread_unmuted_count}"
      end rescue nil
      client.on TD::Types::Update::UnreadChatCount do |u|
        dlog "[UNREAD_CHAT] total=#{u.unread_count} unmuted=#{u.unread_unmuted_count}"
      end rescue nil
      client.on TD::Types::Update::ConnectionState do |u|
        dlog "[NET] state=#{u.state.class.name.split('::').last}"
      end rescue nil

      # Print a single line when the bot is fully authorized
      client.on TD::Types::Update::AuthorizationState do |update|
        if update.authorization_state.is_a?(TD::Types::AuthorizationState::Ready)
          puts "[ONLINE] TDLib authorization is READY"
          begin
            @self_id = td.get_me.value.id
            dlog "[SELF] user_id=#{@self_id}"
          rescue => e
            dlog "self_id_error: #{e.class}: #{e.message}"
          end
          @auth_ready = true
          if defined?(@listen_handler) && @listen_handler && !@startup_unread_processed
            process_unread_on_start @listen_handler
            @startup_unread_processed = true
          end
        end
      end
    end

    def listen(&handler)
      dlog "[LISTEN] waiting for messages..."
      @listen_handler = handler
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
        dlog "[MSG] incoming: #{text.to_s[0,80]}" if text
        unless defined?(@__first_recv_logged) && @__first_recv_logged
          dlog "[RECV] first message update received"
          @__first_recv_logged = true
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
        # Ignore messages sent by the bot itself (identified by user id) or outgoing
        @self_id ||= td.get_me.value.id
        if orig_msg.respond_to?(:is_outgoing) && orig_msg.is_outgoing
          dlog "[SKIP] outgoing message id=#{orig_msg.id}"
          next
        end
        if (sid = msg.sender_id)&.respond_to?(:user_id)
          if sid.user_id == @self_id
            dlog "[SKIP] self message id=#{orig_msg.id}"
            next
          end
        end

        # Mark original message as read immediately
        mark_read msg

        handler.call msg if handler
      end
    end

    # Fetch and process all unread messages for all chats at startup, ignoring mute state
    def process_unread_on_start(handler)
      td = self.td
      self_id = (@self_id || td.get_me.value.id) rescue nil
      # Ensure chat lists are loaded so get_chats returns results
      load_all_chats TD::Types::ChatList::Main.new rescue nil
      load_all_chats TD::Types::ChatList::Archive.new rescue nil
      # Collect chat ids from both Main and Archive lists using multiple fallbacks
      chat_ids = []
      main_ids = []
      arch_ids = []
      begin
        main_ids = td.get_chats(chat_list: TD::Types::ChatList::Main.new, limit: 1000).value.chat_ids rescue []
        arch_ids = td.get_chats(chat_list: TD::Types::ChatList::Archive.new, limit: 1000).value.chat_ids rescue []
      rescue; end
      if main_ids.empty? && arch_ids.empty?
        main_ids = td.get_chats(limit: 1000).value.chat_ids rescue []
      end
      chat_ids = (main_ids + arch_ids).uniq
      dlog "[UNREAD_SCAN] main=#{main_ids.size} archive=#{arch_ids.size} total=#{chat_ids.size}"
      chat_ids.each do |cid|
        begin
          chat = td.get_chat(chat_id: cid).value
        rescue
          next
        end
        last_read = chat.last_read_inbox_message_id.to_i
        processed = 0
        from_id = 0 # 0 means start from latest
        loop do
          msgs = (td.get_chat_history(chat_id: cid, from_message_id: from_id, offset: 0, limit: 100, only_local: false).value.messages rescue [])
          break if msgs.empty?
          min_id = msgs.map { |m| m.id.to_i }.min
          unread_msgs = msgs.select { |m| m.id.to_i > last_read }
          unread_msgs.reverse_each do |orig_msg|
            begin
              # Skip self-sent or outgoing messages
              if self_id && (sid = orig_msg.sender_id)&.respond_to?(:user_id)
                if sid.user_id == self_id
                  dlog "[SKIP] startup self msg id=#{orig_msg.id}"
                  next
                end
              end
              if orig_msg.respond_to?(:is_outgoing) && orig_msg.is_outgoing
                dlog "[SKIP] startup outgoing msg id=#{orig_msg.id}"
                next
              end

              text = case orig_msg.content
              when TD::Types::MessageContent::Text
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
                  from: {id: (orig_msg.sender_id.respond_to?(:user_id) ? orig_msg.sender_id.user_id : nil)},
                  text: text.to_s,
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

              dlog "[RECV] startup unread: chat=#{msg.chat_id} id=#{msg.id}"
              processed += 1
              # Mark as read first so processing exceptions don't block read-status
              mark_read msg
              handler.call msg if handler
            rescue => e
              dlog "startup_unread_error: #{e.class}: #{e.message}"
            end
          end
          break if min_id <= last_read
          from_id = min_id - 1
        end
        dlog "[UNREAD_SCAN] chat=#{cid} last_read=#{last_read} processed=#{processed}"
      end
    rescue => e
      dlog "unread_scan_error: #{e.class}: #{e.message}"
    end

    # Proactively load chats so TDLib has them available for get_chats
    def load_all_chats(chat_list=nil, limit: 200)
      5.times do |i|
        begin
          td.load_chats chat_list: chat_list, limit: limit
          dlog "[LOAD] chats phase=#{i+1} list=#{chat_list&.class&.name&.split('::')&.last || 'Main'}"
          sleep 0.2
        rescue => e
          dlog "load_chats_error: #{e.class}: #{e.message}"
          break
        end
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
      dlog "[READ] chat=#{msg.chat_id} id=#{msg.id}"
    rescue => e
      dlog "mark_read_error: #{e.class}: #{e.message}"
    end

    # All TDLib compatibility patches live in td_bot/compat.rb

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
