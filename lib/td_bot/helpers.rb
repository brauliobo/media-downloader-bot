require 'set'
require 'fileutils'
require 'limiter'
require 'retriable'
require_relative '../bot/rate_limiter'

class TDBot
  include TD::Logging
  
  module Helpers

    extend ActiveSupport::Concern
    include MsgHelpers
    include Bot::RateLimiter

    included do
      class_attribute :td, :client, :message_handler, :message_sender, :file_manager
      
      # Configure TDLib client
      TD::Client.configure_for_bot
      
      # Initialize client and components
      self.client = self.td = TD::Client.new timeout: 1.minute
      self.message_handler = TD::MessageHandler.new(client)
      self.message_sender = TD::MessageSender.new(client)
      self.file_manager = TD::FileManager.new(client)
      
      # Setup authentication
      client.setup_authentication_handlers

      # Rate limiters
      rate_limits global: 20, per_chat: 1
    end
    
    def td_retry_after_seconds(e)
      e.message[/retry after (\d+)/, 1]&.to_i || 60
    end

    def listen(&handler)
      dlog "[LISTEN] waiting for messages..."
      
      # Setup message handling
      message_handler.setup_handlers(&handler)
      
      # Process unread messages if enabled
      if ENV['TDLIB_PROCESS_UNREAD'].to_s == '1'
        Thread.new do
          dlog "[UNREAD_THREAD] starting wait for auth"
          if client.wait_for_ready(timeout: 600)
            message_handler.process_unread_messages
          else
            dlog "[UNREAD_THREAD] timeout waiting for auth"
          end
        end
      else
        dlog "[UNREAD_KICK] skipped (TDLIB_PROCESS_UNREAD!=1)"
      end
    end

    # TDLib-specific markdown escaping - minimal for proper formatting
    def me(text)
      return text unless text
      # For TDLib, we need minimal escaping to allow markdown to work
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

    # Download any Telegram file (audio, video, document) via TDLib
    def download_file(file_id_or_info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: nil)
      # Use the enhanced file_manager method
      result = file_manager.download_file(file_id_or_info, priority: priority, offset: offset, limit: limit, synchronous: synchronous, dir: dir)
      
      # Check for errors in the download result
      if result.is_a?(Hash) && result[:error]
        raise "Failed to download file: #{result[:error]}"
      end
      
      # Extract the local path from the file manager result hash
      local_path = result.is_a?(Hash) ? result[:local_path] : nil
      
      # Ensure we always return a string path
      raise "Failed to download file: no local path available (got: #{result.inspect})" unless local_path && !local_path.empty?
      
      local_path
    end

    # TDLib-specific caption formatting that handles URLs properly
    def msg_caption(i)
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

    # High-level message sending interface
    def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
      t = type.to_s
      
      ret = td_with_rate_limit('send_message') do
        throttle! msg.chat.id, :high

        # Add reply-to information if original message exists
        reply_to = nil
        if msg.respond_to?(:id)
          reply_to = msg.id
        elsif msg.respond_to?(:message_id)
          reply_to = msg.message_id
        end
        dlog "[TD_SEND_MESSAGE] reply_to=#{reply_to} msg.class=#{msg.class}"

        result = nil
        if t.in? %w[message text]
          Manager.retriable(tries: 3, base_interval: 0.3, multiplier: 2.0) do |attempt|
            reply_to = nil if attempt == 1
            result = message_sender.send_text(msg.chat.id, text, parse_mode: parse_mode, reply_to: reply_to)
          end
        elsif params[:audio]
          result = message_sender.send_audio(msg.chat.id, text, reply_to: reply_to, **params)
        elsif params[:video]
          result = message_sender.send_video(msg.chat.id, text, reply_to: reply_to, **params)
        elsif params[:document]
          result = message_sender.send_document(msg.chat.id, text, reply_to: reply_to, **params)
        else
          preview = text.to_s.gsub(/\s+/, ' ')[0, 200]
          dlog "[TD_SEND] type=#{type} chat=#{msg.chat.id} text=#{preview}"
          result = { message_id: (Time.now.to_f * 1000).to_i, text: text }
        end
        SymMash.new(result)
      end
      ret || SymMash.new(message_id: 0, text: text)
    end

    def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params)
      td_with_rate_limit('edit_message') do
        return if throttle!(msg.chat.id, :low, discard: true, message_id: id) == :discard
        Manager.retriable(tries: 3, base_interval: 0.3, multiplier: 2.0) do |_attempt|
          message_sender.edit_message(msg.chat.id, id, text, parse_mode: parse_mode)
        end
      end
    end

    def delete_message(msg, id, wait: nil)
      result = message_sender.delete_message_public(msg.chat.id, id)
      dlog "[TD_DELETE] wait=#{wait} result=#{result ? 'success' : 'failed'}"
      result
    end

    def mark_read(msg)
      client.view_messages(chat_id: msg.chat_id, message_ids: [msg.id], source: nil, force_read: true)
      dlog "[READ] chat=#{msg.chat_id} id=#{msg.id}"
    rescue => e
      dlog "[READ_ERROR] #{e.class}: #{e.message}"
    end

    # Legacy compatibility method for direct editing - use edit_message instead
    def edit(msg, text)
      edit_message(msg, msg.id, text: text)
    end

    private

    def td_with_rate_limit(tag)
      begin
        return yield
      rescue TD::Error => e
        if e.message.include?('429') || e.message.include?('Too Many Requests')
          ra = td_retry_after_seconds(e); dlog "[RATE_LIMIT] TDLib sleeping #{ra}s (#{tag})"; sleep ra; retry
        end
        dlog "[TD_ERROR] #{e.class}: #{e.message}"
        nil
      rescue => e
        dlog "[TD_ERROR] #{e.class}: #{e.message}"
        nil
      end
    end
  end
end