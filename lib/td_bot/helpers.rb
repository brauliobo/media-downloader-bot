require_relative 'markdown'
require 'set'
require 'io/console'
require 'fileutils'

class TDBot
  def self.dlog(msg); puts msg if ENV['TDLOG'].to_i > 0; end
  module Helpers

    include MsgHelpers

    def dlog(msg); TDBot.dlog(msg); end

    TD.configure do |config|
      config.client.api_id   = ENV['TDLIB_API_ID']
      config.client.api_hash = ENV['TDLIB_API_HASH']
      base   = ENV['TDLIB_BASE_DIR'] || File.join(Dir.pwd, '.tdlib')
      db_dir = File.join(base, 'db')
      fs_dir = File.join(base, 'files')
      begin
        FileUtils.mkdir_p [db_dir, fs_dir]
      rescue
      end
      config.client.database_directory = db_dir
      config.client.files_directory    = fs_dir
    end
    puts "[TD_CONF] api_id=#{ENV['TDLIB_API_ID'].to_s.sub(/\d{3}\d+/, '***')} api_hash=#{(ENV['TDLIB_API_HASH']||'')[0,3]}*** db=#{TD.config.client.database_directory} files=#{TD.config.client.files_directory}" if ENV['TDLOG'].to_i > 0
    puts "[TD_ENV] present_api_id=#{!ENV['TDLIB_API_ID'].to_s.empty?} present_api_hash=#{!ENV['TDLIB_API_HASH'].to_s.empty?}" if ENV['TDLOG'].to_i > 0
    TD::Api.set_log_verbosity_level 0

    extend ActiveSupport::Concern
    included do
      class_attribute :td, :client
      self.client = self.td = TD::Client.new timeout: 1.minute

      # Map [chat_id, temporary_id] -> final_id
      @@msg_id_map = {}
      @@known_chat_ids = Set.new
      @@pending_last_messages = []

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
      # Log option changes that might affect message delivery
      begin
        client.on TD::Types::Update::Option do |u|
          dlog "[OPT] #{u.name}=#{u.value.class.name.split('::').last}"
        end
      rescue; end

      # Track chats seen via updates so we can query them even if get_chats fails
      begin
        client.on TD::Types::Update::NewChat do |u|
          cid = (u.chat&.id rescue nil)
          @@known_chat_ids << cid if cid
          # Process last_message when available
          if u.chat && u.chat.respond_to?(:last_message) && u.chat.last_message
            dlog "[FALLBACK] NewChat last_message chat=#{cid} id=#{u.chat.last_message.id}"
            handle_incoming_message(u.chat.last_message, handler)
          end
        end
        client.on TD::Types::Update::ChatAddedToList do |u|
          @@known_chat_ids << u.chat_id if u.respond_to?(:chat_id)
        end
        client.on TD::Types::Update::ChatPosition do |u|
          @@known_chat_ids << u.chat_id if u.respond_to?(:chat_id)
        end
      rescue; end

      # Auth state / READY
      client.on TD::Types::Update::AuthorizationState do |update|
        state_name = update.authorization_state.class.name.split('::').last
        dlog "[AUTH] state=#{state_name}"
        if update.authorization_state.is_a?(TD::Types::AuthorizationState::WaitTdlibParameters)
          dlog "[AUTH] waiting tdlib params; api_id?=#{!ENV['TDLIB_API_ID'].to_s.empty?} api_hash?=#{!ENV['TDLIB_API_HASH'].to_s.empty?} db=#{TD.config.client.database_directory} files=#{TD.config.client.files_directory}"
          # tdlib-ruby will push parameters automatically on connect
        end
        if update.authorization_state.is_a?(TD::Types::AuthorizationState::WaitPhoneNumber)
          dlog "[AUTH] waiting phone number"
          begin
            phone = ENV['TDLIB_PHONE']
            unless phone && !phone.empty?
              print "Enter phone number with +CC (e.g. +15551234567): "
              STDOUT.flush
              phone = STDIN.gets&.strip
            end
            if phone && !phone.empty?
              td.set_authentication_phone_number phone_number: phone, settings: nil
              dlog "[AUTH] phone submitted"
            else
              dlog "[AUTH] phone not provided"
            end
          rescue => e
            dlog "[AUTH] phone_error: #{e.class}: #{e.message}"
          end
        end
        if update.authorization_state.is_a?(TD::Types::AuthorizationState::WaitCode)
          dlog "[AUTH] waiting login code"
          begin
            code = ENV['TDLIB_CODE']
            unless code && !code.empty?
              print "Enter code (from Telegram): "
              STDOUT.flush
              code = STDIN.gets&.strip
            end
            if code && !code.empty?
              td.check_authentication_code code: code
              dlog "[AUTH] code submitted"
            else
              dlog "[AUTH] code not provided"
            end
          rescue => e
            dlog "[AUTH] code_error: #{e.class}: #{e.message}"
          end
        end
        if update.authorization_state.is_a?(TD::Types::AuthorizationState::WaitPassword)
          dlog "[AUTH] waiting 2FA password"
          begin
            pass = ENV['TDLIB_PASSWORD']
            unless pass && !pass.empty?
              print "Enter 2FA password: "
              STDOUT.flush
              pass = STDIN.noecho(&:gets)&.strip
              puts
            end
            if pass && !pass.empty?
              td.check_authentication_password password: pass
              dlog "[AUTH] password submitted"
            else
              dlog "[AUTH] password not provided"
            end
          rescue => e
            dlog "[AUTH] password_error: #{e.class}: #{e.message}"
          end
        end
        if update.authorization_state.is_a?(TD::Types::AuthorizationState::Ready)
          puts "[READY] TDLib authorization is READY"
          dlog "[READY_DEBUG] starting ready handler"
          @auth_ready = true
          # Set a class-level flag that instances can check
          self.class.instance_variable_set(:@auth_ready, true)
          dlog "[AUTH_READY] flag set, instances can now process unread"
          # Try to cache self id via option to avoid get_me failures
          begin
            opt = td.get_option(name: 'my_id').value(5) rescue nil
            if opt && opt.respond_to?(:value)
              @self_id = opt.value
              dlog "[SELF_OPT] my_id=#{@self_id}"
            end
          rescue => e
            dlog "[SELF_OPT] error: #{e.class}: #{e.message}"
          end
        end
      end
    end

    def listen(&handler)
      dlog "[LISTEN] waiting for messages..."
      @listen_handler = handler
      self.class.instance_variable_set(:@listen_handler, handler)
      self.class.instance_variable_set(:@listen_instance, self)
      dlog "[LISTEN] handler set: instance=#{!!@listen_handler} class=#{!!self.class.instance_variable_get(:@listen_handler)}"
      # Kick unread scan immediately
      if ENV['TDLIB_PROCESS_UNREAD'].to_s == '1'
        begin
          dlog "[UNREAD_KICK] starting"
          process_unread_on_start handler
        rescue => e
          dlog "unread_kick_error: #{e.class}: #{e.message}"
        end
      else
        dlog "[UNREAD_KICK] skipped (TDLIB_PROCESS_UNREAD!=1)"
      end
      # Trigger unread once READY; poll briefly if needed
      Thread.new do
        dlog "[UNREAD_THREAD] starting wait for auth"
        600.times do |i|
          auth_ready = @auth_ready
          class_auth_ready = self.class.instance_variable_get(:@auth_ready)
          auth_state_ready = (td.get_authorization_state.value.authorization_state.is_a?(TD::Types::AuthorizationState::Ready) rescue false)
          dlog "[UNREAD_THREAD] poll #{i}: @auth_ready=#{auth_ready} class_auth_ready=#{class_auth_ready} state_ready=#{auth_state_ready}" if i % 50 == 0
          break if (auth_ready || class_auth_ready || auth_state_ready)
          sleep 0.2
        end
        if ENV['TDLIB_PROCESS_UNREAD'].to_s == '1'
          begin
            dlog "[UNREAD_KICK_READY] starting"
            process_unread_on_start(handler)
          rescue => e
            dlog "unread_kick_ready_error: #{e.class}: #{e.message}"
          end
        else
          dlog "[UNREAD_KICK_READY] skipped (TDLIB_PROCESS_UNREAD!=1)"
        end
      end
      
      # Debug: log all updates to see what's being received
      dlog "[DEBUG] registering general update handler to see all updates"
      client.on TD::Types::Update do |update|
        type = update.class.name.split('::').last
        relevant = false
        begin
          relevant ||= (update.respond_to?(:message) && !!update.message)
          relevant ||= (update.respond_to?(:last_message) && !!update.last_message)
          if !relevant && update.respond_to?(:chat) && update.chat
            relevant ||= (update.chat.respond_to?(:last_message) && !!update.chat.last_message)
          end
          # Heuristic: anything with "Message" in type is likely relevant
          relevant ||= (type.include?("Message") || type.include?("NewChat"))
        rescue
        end

        payload = begin
          update.respond_to?(:to_h) ? update.to_h : update.inspect
        rescue
          update.inspect
        end

        if relevant
          puts "[UPDATE] received: #{type} #{payload}"
        else
          brief = begin
            s = payload.is_a?(String) ? payload : payload.inspect
            s[0,50]
          rescue
            payload.to_s[0,50]
          end
          puts "[UPDATE] received: #{type} #{brief}..."
        end
      end rescue nil
      
      dlog "[DEBUG] registering Update::NewMessage handler"
      begin
        client.on TD::Types::Update::NewMessage do |update|
        dlog "[NEW_MSG] received new message update"
        handle_incoming_message(update.message, handler)
        end
      rescue => e
        dlog "[DEBUG] error registering Update::NewMessage handler: #{e.class}: #{e.message}"
      end
      
      # Handle message send success to update message ID mapping
      begin
        client.on TD::Types::Update::MessageSendSucceeded do |u|
          if u.respond_to?(:old_message_id) && u.respond_to?(:message) && u.message.respond_to?(:id)
            @@message_id_map ||= {}
            old_id = u.old_message_id
            new_id = u.message.id
            @@message_id_map[old_id] = new_id
            dlog "[MSG_ID_UPDATE] #{old_id} -> #{new_id}"
          end
        end
      rescue => e
        dlog "[DEBUG] error registering MessageSendSucceeded handler: #{e.class}: #{e.message}"
      end

      # Fallback: some environments don't emit Update::NewMessage reliably; process last_message
      begin
        dlog "[DEBUG] registering Update::ChatLastMessage fallback handler"
        client.on TD::Types::Update::ChatLastMessage do |u|
          next unless u.respond_to?(:last_message) && u.last_message
          dlog "[FALLBACK] ChatLastMessage chat=#{u.chat_id} id=#{u.last_message.id}"
          @@known_chat_ids << u.chat_id if u.respond_to?(:chat_id)
          # Queue for startup unread processing
          @@pending_last_messages << u.last_message
          handle_incoming_message(u.last_message, handler) if ENV['TDLIB_PROCESS_UNREAD'].to_s == '1'
        end
      rescue => e
        dlog "[DEBUG] error registering ChatLastMessage handler: #{e.class}: #{e.message}"
      end
    end

    # Fetch and process all unread messages for all chats at startup, ignoring mute state
    def process_unread_on_start(handler)
      td = self.td
      # Check if authorization is ready using multiple methods
      auth_state = (td.get_authorization_state.value.authorization_state rescue nil)
      class_auth_ready = self.class.instance_variable_get(:@auth_ready)
      instance_auth_ready = @auth_ready
      
      auth_ready = auth_state.is_a?(TD::Types::AuthorizationState::Ready) || class_auth_ready || instance_auth_ready
      unless auth_ready
        dlog "[UNREAD_SKIP] auth not ready: state=#{auth_state&.class&.name&.split('::')&.last} class_ready=#{class_auth_ready} instance_ready=#{instance_auth_ready}"
        return
      end
      dlog "[UNREAD_PROCEED] auth ready: state=#{auth_state&.class&.name&.split('::')&.last} class_ready=#{class_auth_ready} instance_ready=#{instance_auth_ready}"
      @startup_unread_processed = true
      self.class.instance_variable_set(:@startup_unread_processed, true)
      # Get self_id and set online status - this is crucial for message sync
      self_id = @self_id
      unless self_id
        begin
          dlog "[UNREAD_PROCEED] getting self_id for proper bot initialization"
          me_result = td.get_me.value(15) # Give it more time
          if me_result && me_result.respond_to?(:id)
            self_id = me_result.id
            @self_id = self_id
            dlog "[SELF] user_id=#{self_id}"
          else
            dlog "[SELF] get_me returned invalid result: #{me_result.class}"
            self_id = nil
          end
        rescue => e
          dlog "[SELF] error getting self_id: #{e.class}: #{e.message}, proceeding without it"
          self_id = nil
        end
      end
      
        # Set online status and message-related options
        begin
          dlog "[ONLINE] setting bot as online"
          td.set_option(name: 'online', value: TD::Types::OptionValue::Boolean.new(value: true)).value(10)
          dlog "[ONLINE] bot marked as online successfully"
          
          # Try to enable message updates explicitly
          dlog "[OPTIONS] enabling message updates"
          td.set_option(name: 'use_message_database', value: TD::Types::OptionValue::Boolean.new(value: true)).value(5) rescue nil
          td.set_option(name: 'use_chat_info_database', value: TD::Types::OptionValue::Boolean.new(value: true)).value(5) rescue nil
          td.set_option(name: 'notification_group_count_max', value: TD::Types::OptionValue::Integer.new(value: 100)).value(5) rescue nil
          td.set_option(name: 'notification_group_size_max', value: TD::Types::OptionValue::Integer.new(value: 10)).value(5) rescue nil
          td.set_option(name: 'receive_all_update_messages', value: TD::Types::OptionValue::Boolean.new(value: true)).value(5) rescue nil
          
          # Debug: Test various TDLib functions to see which ones work
          dlog "[DEBUG] Testing TDLib functions..."
          
          # Test 1: get_me
          me_info = td.get_me.value(5) rescue nil
          dlog "[DEBUG] get_me: #{me_info ? 'SUCCESS' : 'FAILED'}"
          
          # Test 2: get_authorization_state
          auth_state = td.get_authorization_state.value(5) rescue nil
          dlog "[DEBUG] get_authorization_state: #{auth_state ? 'SUCCESS' : 'FAILED'}"
          
          # Test 3: get_option
          online_option = td.get_option(name: 'online').value(5) rescue nil
          dlog "[DEBUG] get_option(online): #{online_option ? 'SUCCESS' : 'FAILED'}"
          
          # Test 4: get_chats (simple)
          chats_result = td.get_chats(limit: 5).value(5) rescue nil
          dlog "[DEBUG] get_chats: #{chats_result ? "SUCCESS (#{chats_result.chat_ids&.size} chats)" : 'FAILED'}"
          
          # Test 5: Try a specific chat
          if chats_result && chats_result.chat_ids && !chats_result.chat_ids.empty?
            first_chat_id = chats_result.chat_ids.first
            chat_info = td.get_chat(chat_id: first_chat_id).value(5) rescue nil
            dlog "[DEBUG] get_chat(#{first_chat_id}): #{chat_info ? 'SUCCESS' : 'FAILED'}"
            
            # Test 6: get_chat_history for this chat
            if chat_info
              history = td.get_chat_history(
                chat_id: first_chat_id,
                from_message_id: 0,
                offset: 0,
                limit: 1,
                only_local: false
              ).value(5) rescue nil
              dlog "[DEBUG] get_chat_history(#{first_chat_id}): #{history ? "SUCCESS (#{history.messages&.size} msgs)" : 'FAILED'}"
            end
          end
          
          # Open a few recent chats to nudge TDLib to emit message updates
          begin
            subscribe_to_recent_chats(td)
          rescue => e
            dlog "[SUBSCRIBE] error: #{e.class}: #{e.message}"
          end
          
          dlog "[OPTIONS] message update options set"
        rescue => e
          dlog "[ONLINE] error setting online status: #{e.class}: #{e.message}"
        end
      
      # No delays - process immediately
      dlog "[UNREAD_PROCEED] processing unread messages immediately"
      started_at = Time.now
      dlog "[UNREAD_PROCEED] self_id=#{self_id} starting chat scan"
      # Ensure chat lists are loaded so get_chats returns results
      load_all_chats TD::Types::ChatList::Main.new rescue nil
      load_all_chats TD::Types::ChatList::Archive.new rescue nil
      # Collect chat ids with robust fallbacks
      chat_ids = []
      main_ids = (td.get_chats(chat_list: TD::Types::ChatList::Main.new, limit: 1000).value.chat_ids rescue [])
      arch_ids = (td.get_chats(chat_list: TD::Types::ChatList::Archive.new, limit: 1000).value.chat_ids rescue [])
      chat_ids = (main_ids + arch_ids).uniq
      chat_ids = (td.get_chats(limit: 1000).value.chat_ids rescue []) if chat_ids.empty?
      chat_ids = (td.search_chats(query: '', limit: 1000).value.chat_ids rescue []) if chat_ids.empty?
      dlog "[UNREAD_SCAN] main=#{main_ids.size} archive=#{arch_ids.size} total=#{chat_ids.size}"
      # DIRECT APPROACH: Use brute force to get messages from all chats
      dlog "[UNREAD_DIRECT] trying global search approach since individual chat fetching fails"
      processed_messages = 0
      
      # Global search approach: use schema-correct signature to fetch recent messages
      begin
        dlog "[GLOBAL] searching messages (schema signature)"
        global_search = td.search_messages(
          chat_list: TD::Types::ChatList::Main.new,
          only_in_channels: false,
          query: "",
          offset: 0,
          limit: 100,
          filter: nil,
          min_date: 0,
          max_date: 0
        ).value(20) rescue nil
        
        if global_search && global_search.respond_to?(:messages) && global_search.messages && !global_search.messages.empty?
          dlog "[GLOBAL] found #{global_search.messages.size} messages"
          
          # Process recent messages
          global_search.messages.first(30).each do |orig_msg|
                break if processed_messages >= 10
                
                # Skip outgoing/self/service/channel/chat-sent
                next if orig_msg.respond_to?(:is_outgoing) && orig_msg.is_outgoing
                next if self_id && orig_msg.sender_id.respond_to?(:user_id) && orig_msg.sender_id.user_id == self_id
                next if orig_msg.respond_to?(:is_channel_post) && orig_msg.is_channel_post
                next if orig_msg.sender_id.respond_to?(:chat_id)
                next if orig_msg.sender_id.respond_to?(:user_id) && orig_msg.sender_id.user_id == 777000
                
                # Extract message text using the patched method
                text = orig_msg.text rescue (orig_msg.content.text&.text rescue nil)
                
                # Only process messages with content
                next if text.nil? || text.empty?
                
                # Create message object for handler
                msg = SymMash.new(
                  orig_msg.to_h.merge(
                    chat: {id: orig_msg.chat_id},
                    from: {id: (orig_msg.sender_id.respond_to?(:user_id) ? orig_msg.sender_id.user_id : nil)},
                    text: text.to_s,
                  )
                )
                
                # Display the message
                puts "[UNREAD_MSG] chat=#{orig_msg.chat_id} id=#{orig_msg.id} #{text[0,80]}"
                STDOUT.flush rescue nil
                
                # Mark as read
                begin
                  td.view_messages(
                    chat_id: orig_msg.chat_id,
                    message_ids: [orig_msg.id],
                    source: nil,
                    force_read: true
                  )
                  dlog "[READ] marked message #{orig_msg.id} as read"
                rescue => e
                  dlog "[READ_ERROR] #{e.class}: #{e.message}"
                end
                
                # Call the handler (Bot#react)
                begin
                  dlog "[HANDLER] calling Bot#react for message id=#{orig_msg.id}"
                  handler.call msg if handler
                  dlog "[HANDLER] Bot#react completed for message id=#{orig_msg.id}"
                  processed_messages += 1
                rescue => e
                  dlog "[HANDLER] error in Bot#react: #{e.class}: #{e.message}"
                end
          end
        else
          dlog "[GLOBAL] no messages returned"
        end
      rescue => e
        dlog "[GLOBAL] error: #{e.class}: #{e.message}"
      end

      # Per-chat fallback search using chat ids learned via updates
      if processed_messages < 10 && defined?(@@known_chat_ids) && @@known_chat_ids && !@@known_chat_ids.empty?
        dlog "[CHAT_SEARCH] scanning #{@@known_chat_ids.size} known chats"
        @@known_chat_ids.first(50).each do |cid|
          break if processed_messages >= 10
          begin
            found = td.search_chat_messages(
              chat_id: cid,
              query: "",
              sender_id: nil,
              from_message_id: 0,
              offset: 0,
              limit: 30,
              filter: nil,
              message_thread_id: 0,
              saved_messages_topic_id: 0
            ).value(10) rescue nil
            msgs = (found&.messages || [])
            next if msgs.empty?
            dlog "[CHAT_SEARCH] chat=#{cid} messages=#{msgs.size}"
            msgs.each do |orig_msg|
              break if processed_messages >= 10
              # quick date/flag sanity: prefer recent, unread-like
              begin
                # If the server provides interaction_info with unread_count, prefer those
                if orig_msg.respond_to?(:interaction_info) && orig_msg.interaction_info && orig_msg.interaction_info.respond_to?(:view_count)
                  # no-op, keep for future heuristics
                end
              rescue; end
              next if orig_msg.respond_to?(:is_outgoing) && orig_msg.is_outgoing
              next if self_id && orig_msg.sender_id.respond_to?(:user_id) && orig_msg.sender_id.user_id == self_id
              next if orig_msg.respond_to?(:is_channel_post) && orig_msg.is_channel_post
              next if orig_msg.sender_id.respond_to?(:chat_id)
              next if orig_msg.sender_id.respond_to?(:user_id) && orig_msg.sender_id.user_id == 777000
              text = orig_msg.text rescue (orig_msg.content.text&.text rescue nil)
              next if text.nil? || text.empty?
              msg = SymMash.new(orig_msg.to_h.merge(chat: {id: orig_msg.chat_id}, from: {id: (orig_msg.sender_id.respond_to?(:user_id) ? orig_msg.sender_id.user_id : nil)}, text: text.to_s))
              puts "[UNREAD_MSG] chat=#{orig_msg.chat_id} id=#{orig_msg.id} #{text[0,80]}"; STDOUT.flush rescue nil
              begin
                td.view_messages(chat_id: orig_msg.chat_id, message_ids: [orig_msg.id], source: nil, force_read: true)
              rescue; end
              begin
                handler.call msg if handler
                processed_messages += 1
              rescue => e
                dlog "[HANDLER] error: #{e.class}: #{e.message}"
              end
            end
          rescue => e
            dlog "[CHAT_SEARCH] error chat=#{cid}: #{e.class}: #{e.message}"
          end
        end
      end
      
      dlog "[UNREAD_COMPLETE] processed #{processed_messages} unread messages"
    end

    def edit(msg, text)
      client.edit_message_text(
        chat_id: msg.chat_id,
        message_id: msg.id,
        input_message_content: TD::Types::InputMessageContent::Text.new(
          text: TD::Types::FormattedText.new(text: text, entities: [])
        )
      ).value
    rescue => e
      STDERR.puts "edit_error: #{e.class}: #{e.message}"
    end

    # Centralized message handling used by all update sources
    def handle_incoming_message(orig_msg, handler)
      return unless orig_msg
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

      @self_id ||= begin
        (td.get_option(name: 'my_id').value(2) rescue nil) || (td.get_me.value(2).id rescue nil)
      end
      return if orig_msg.respond_to?(:is_outgoing) && orig_msg.is_outgoing
      if @self_id && (sid = orig_msg.sender_id)&.respond_to?(:user_id)
        return if sid.user_id == @self_id
      end
      return if orig_msg.respond_to?(:is_channel_post) && orig_msg.is_channel_post
      return if (orig_msg.sender_id rescue nil)&.respond_to?(:chat_id)
      if (sid = orig_msg.sender_id rescue nil)&.respond_to?(:user_id)
        return if sid.user_id == 777000
      end
      # Keep processing of plain text (commands/help) even if no URL

      dlog "[MSG] incoming id=#{orig_msg.id} chat=#{orig_msg.chat_id} type=#{orig_msg.content.class.name.split('::').last}"
      return if orig_msg.respond_to?(:is_channel_post) && orig_msg.is_channel_post
      return if (orig_msg.sender_id rescue nil)&.respond_to?(:chat_id)

      msg = SymMash.new(
        orig_msg.to_h.merge(
          chat: { id: orig_msg.chat_id },
          from: { id: (orig_msg.sender_id.respond_to?(:user_id) ? orig_msg.sender_id.user_id : nil) },
          text: text
        )
      )

      case orig_msg.content
      when TD::Types::MessageContent::Audio then msg[:audio] = orig_msg.content.audio
      when TD::Types::MessageContent::Video then msg[:video] = orig_msg.content.video
      when TD::Types::MessageContent::Document then msg[:document] = orig_msg.content.document
      end

      mark_read msg
      handler&.call(msg)
    rescue => e
      dlog "[MSG_ERROR] #{e.class}: #{e.message}"
    end

    # Ask TDLib to load chats and briefly open them to kick message updates
    def subscribe_to_recent_chats(td)
      lists = [TD::Types::ChatList::Main.new, TD::Types::ChatList::Archive.new]
      lists.each do |lst|
        td.load_chats(chat_list: lst, limit: 50).value(5) rescue nil
      end
      chat_ids = (td.get_chats(chat_list: TD::Types::ChatList::Main.new, limit: 50).value.chat_ids rescue [])
      chat_ids.first(10).each do |cid|
        begin
          td.open_chat(chat_id: cid).value(3) rescue nil
          td.close_chat(chat_id: cid).value(3) rescue nil
        rescue
        end
      end
    end

    def mark_read msg
      client.view_messages chat_id: msg.chat_id, message_ids: [msg.id], source: nil, force_read: true
      dlog "[READ] chat=#{msg.chat_id} id=#{msg.id}"
    rescue => e
      dlog "mark_read_error: #{e.class}: #{e.message}"
    end

    # TDLib-specific markdown escaping - only escape characters that break parsing
    def me(text)
      return text unless text
      # For TDLib, we need minimal escaping to allow markdown to work
      # Only escape characters that would break the markdown parsing
      text = text.gsub('\\', '\\\\')  # Escape backslashes first
      text = text.gsub('`', '\\`')    # Escape backticks for code formatting
      # Don't escape _ and * - we want them to work for formatting
      # Don't escape [] - TDLib handles URLs automatically
      text
    end
    alias_method :mnfe, :me
    def mfe(text)
      return text unless text
      MsgHelpers::MARKDOWN_FORMAT.each { |c| text = text.gsub(c, "\\#{c}") }
      text
    end

    # Download any Telegram file (audio, video, document) via TDLib and return
    # a hash of {local_path:, remote_id:} for use in the Bot#react handler
    def download_file(file_id, priority: 32, offset: 0, limit: 0, synchronous: true)
      return {error: 'no file_id'} unless file_id
      
      begin
        file_info = client.get_file(file_id: file_id).value(30)
        return {error: 'file info failed'} unless file_info
        
        if file_info.local.is_downloading_completed
          return {
            local_path: file_info.local.path,
            remote_id: file_info.remote.id,
            size: file_info.size
          }
        end
        
        download_result = client.download_file(
          file_id: file_id,
          priority: priority,
          offset: offset,
          limit: limit,
          synchronous: synchronous
        ).value(120)
        
        return {error: 'download failed'} unless download_result
        
        {
          local_path: download_result.local.path,
          remote_id: download_result.remote.id,
          size: download_result.size
        }
      rescue => e
        {error: "#{e.class}: #{e.message}"}
      end
    end

    # TDLib-specific caption formatting that handles URLs properly
    def msg_caption i
      return '' if i.respond_to?(:opts) && i.opts.nocaption
      text = ''
      if (i.respond_to?(:opts) && i.opts.caption) || (i.respond_to?(:type) && i.type == Zipper::Types.video)
        text  = "_#{me i.info.title}_"
        text << "\n#{me i.info.uploader}" if i.info.uploader
      end
      text << "\n\n_#{me i.info.description.strip}_" if i.respond_to?(:opts) && i.opts.description && i.info.description.strip.presence
      # Format URL as clickable link for TDLib
      text << "\n\n#{i.url}" if i.url  # Don't escape URLs - TDLib handles them automatically
      text
    end

    # Minimal stubs to be API-compatible with TlBot for Worker usage
    def send_message msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params
      t = type.to_s
      return send_td_text(msg, text) if t.in? %w[message text]
      return send_td_video(msg, text, **params) if params[:video]
      return send_td_document(msg, text, **params) if params[:document]
      preview = text.to_s.gsub(/\s+/, ' ')[0, 200]
      puts "[TD_SEND] type=#{type} chat=#{msg.chat.id} text=#{preview}"
      SymMash.new message_id: (Time.now.to_f * 1000).to_i, text: text
    rescue => e
      dlog "[TD_SEND_ERROR] #{e.class}: #{e.message}"
      SymMash.new message_id: 0, text: text
    end

    def edit_message msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params
      # Use the correct message ID from mapping if available
      @@message_id_map ||= {}
      actual_id = @@message_id_map[id] || id
      
      dlog "[TD_EDIT] chat=#{msg.chat.id} id=#{id}->#{actual_id} text=#{text.to_s[0,50]}..."
      return if actual_id.to_i <= 0 || text.to_s.empty?
      
      # Parse markdown to get proper formatting entities
      formatted_text = parse_markdown_text(text.to_s)
      
      client.edit_message_text(
        chat_id: msg.chat.id,
        message_id: actual_id,
        input_message_content: TD::Types::InputMessageContent::Text.new(
          text: formatted_text,
          link_preview_options: nil,
          clear_draft: false
        ),
        reply_markup: nil
      ).value(15)
      dlog "[TD_EDIT] success"
    rescue => e
      dlog "[TD_EDIT_ERROR] #{e.class}: #{e.message}"
      dlog "[TD_EDIT_ERROR] backtrace: #{e.backtrace[0,3].join(' | ')}"
    end

    def delete_message msg, id, wait: nil
      client.delete_messages chat_id: msg.chat.id, message_ids: [id], revoke: true
      dlog "[TD_DELETE] chat=#{msg.chat.id} id=#{id} wait=#{wait}"
    rescue => e
      dlog "[TD_DELETE_ERROR] #{e.class}: #{e.message}"
    end

    private
    def send_td_text(msg, text)
      # Parse markdown to get proper formatting entities
      formatted_text = parse_markdown_text(text.to_s)
      
      content = TD::Types::InputMessageContent::Text.new(
        text: formatted_text,
        link_preview_options: nil,
        clear_draft: false
      )
      dlog "[TD_SEND_TEXT] chat=#{msg.chat.id} text=#{text[0,50]}..."
      sent = client.send_message(chat_id: msg.chat.id, message_thread_id: 0, reply_to: nil, options: nil, reply_markup: nil, input_message_content: content).value(15)
      msg_id = sent&.id || 0
      dlog "[TD_SEND_TEXT] sent id=#{msg_id}"
      
      # Track message ID updates for proper editing
      if msg_id > 0
        @@message_id_map ||= {}
        @@message_id_map[msg_id] = msg_id
      end
      
      SymMash.new message_id: msg_id, text: text
    rescue => e
      dlog "[TD_SEND_TEXT_ERROR] #{e.class}: #{e.message}"
      dlog "[TD_SEND_TEXT_ERROR] backtrace: #{e.backtrace[0,3].join(' | ')}"
      SymMash.new message_id: 0, text: text
    end

    def extract_local_path(obj)
      return obj if obj.is_a?(String)
      return obj.path if obj.respond_to?(:path)
      begin
        io = obj.instance_variable_get(:@io)
        return io.path if io && io.respond_to?(:path)
      rescue; end
      nil
    end

    def parse_markdown_text(text)
      return TD::Types::FormattedText.new(text: '', entities: []) if text.to_s.empty?
      
      # Use the existing TDBot::Markdown class which has proper fallback handling
      result = TDBot::Markdown.parse(client, text.to_s)
      dlog "[MARKDOWN_PARSE] '#{text[0,30]}...' -> #{result.entities.length} entities"
      result
    rescue => e
      dlog "[PARSE_MARKDOWN_ERROR] #{e.class}: #{e.message}"
      # Fallback to plain text
      TD::Types::FormattedText.new(text: text.to_s, entities: [])
    end

    def copy_to_safe_location(original_path)
      return original_path unless File.exist?(original_path)
      
      # Create safe upload directory
      safe_dir = File.join(Dir.tmpdir, 'tdbot-uploads')
      FileUtils.mkdir_p(safe_dir)
      
      # Generate unique filename
      basename = File.basename(original_path)
      timestamp = Time.now.to_f.to_s.tr('.', '')
      safe_filename = "#{timestamp}_#{basename}"
      safe_path = File.join(safe_dir, safe_filename)
      
      # Copy file
      FileUtils.cp(original_path, safe_path)
      dlog "[SAFE_COPY] #{original_path} -> #{safe_path}"
      
      # Schedule cleanup after a reasonable delay (5 minutes)
      Thread.new do
        sleep 300
        File.delete(safe_path) if File.exist?(safe_path)
        dlog "[SAFE_CLEANUP] deleted #{safe_path}"
      rescue => e
        dlog "[SAFE_CLEANUP_ERROR] #{e.class}: #{e.message}"
      end
      
      safe_path
    end

    def send_td_video(msg, caption, **params)
      file_obj = params[:video]
      path = extract_local_path(file_obj)
      raise 'video path missing' unless path && !path.empty?
      
      # Copy file to permanent location to avoid cleanup issues
      safe_path = copy_to_safe_location(path)
      
      duration = params[:duration].to_i rescue 0
      width    = params[:width].to_i rescue 0
      height   = params[:height].to_i rescue 0
      supports_streaming = !!params[:supports_streaming]

      content = TD::Types::InputMessageContent::Video.new(
        video: TD::Types::InputFile::Local.new(path: safe_path),
        thumbnail: DUMMY_THUMB,
        added_sticker_file_ids: [],
        duration: duration,
        width: width,
        height: height,
        supports_streaming: supports_streaming,
        caption: parse_markdown_text(caption.to_s),
        show_caption_above_media: false,
        self_destruct_type: nil,
        has_spoiler: false
      )
      sent = client.send_message(chat_id: msg.chat.id, message_thread_id: 0, reply_to: nil, options: nil, reply_markup: nil, input_message_content: content).value(60)
      SymMash.new message_id: (sent&.id || 0), text: caption
    rescue => e
      dlog "[TD_SEND_VIDEO_ERROR] #{e.class}: #{e.message}"
      SymMash.new message_id: 0, text: caption
    end

    def send_td_document(msg, caption, **params)
      file_obj = params[:document]
      path = extract_local_path(file_obj)
      raise 'document path missing' unless path && !path.empty?
      
      # Copy file to permanent location to avoid cleanup issues
      safe_path = copy_to_safe_location(path)
      
      content = TD::Types::InputMessageContent::Document.new(
        document: TD::Types::InputFile::Local.new(path: safe_path),
        thumbnail: DUMMY_THUMB,
        disable_content_type_detection: false,
        caption: parse_markdown_text(caption.to_s)
      )
      sent = client.send_message(chat_id: msg.chat.id, message_thread_id: 0, reply_to: nil, options: nil, reply_markup: nil, input_message_content: content).value(60)
      SymMash.new message_id: (sent&.id || 0), text: caption
    rescue => e
      dlog "[TD_SEND_DOC_ERROR] #{e.class}: #{e.message}"
      SymMash.new message_id: 0, text: caption
    end

  end
end
