require 'set'
require 'fileutils'

class TDBot
  include TD::Logging
  
  module Helpers
    include MsgHelpers

    extend ActiveSupport::Concern
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
      # Handle both file_id (integer) and info object (with document/file_id method)
      if file_id_or_info.respond_to?(:document) && file_id_or_info.document.respond_to?(:file_id)
        # This is a message document object
        file_id = file_id_or_info.document.file_id
      elsif file_id_or_info.respond_to?(:file_id)
        # This is a document or file object with direct file_id
        file_id = file_id_or_info.file_id
      elsif file_id_or_info.respond_to?(:document) && file_id_or_info.document.respond_to?(:id)
        # This is a document object with id field instead of file_id
        file_id = file_id_or_info.document.id
      elsif file_id_or_info.respond_to?(:id)
        # This is a file object with id field
        file_id = file_id_or_info.id
      else
        # This should be a file_id integer
        file_id = file_id_or_info
      end
      
      dlog "[TD_DOWNLOAD] file_id=#{file_id} dir=#{dir}"
      
      # Download the file using TDLib
      result = file_manager.download_file(file_id, priority: priority, offset: offset, limit: limit, synchronous: synchronous)
      
      dlog "[TD_DOWNLOAD] result=#{result.inspect}"
      
      # Check for errors in the download result
      if result.is_a?(Hash) && result[:error]
        raise "Failed to download file: #{result[:error]}"
      end
      
      # Extract the local path from the file manager result hash
      local_path = result.is_a?(Hash) ? result[:local_path] : nil
      dlog "[TD_DOWNLOAD] extracted path=#{local_path} exists=#{File.exist?(local_path) if local_path}"
      
      # If dir is specified and we have a valid local path, copy the file to the desired directory
      if dir && local_path && !local_path.empty? && File.exist?(local_path)
        filename = File.basename(local_path)
        target_path = File.join(dir, filename)
        
        dlog "[TD_DOWNLOAD] copying #{local_path} -> #{target_path}"
        # Ensure target directory exists
        FileUtils.mkdir_p(dir)
        # Copy file to target directory
        FileUtils.cp(local_path, target_path)
        return target_path
      end
      
      # Ensure we always return a string path
      final_path = local_path && !local_path.empty? ? local_path : nil
      dlog "[TD_DOWNLOAD] final_path=#{final_path} (class=#{final_path.class})"
      
      # If we don't have a valid path, raise an error
      raise "Failed to download file: no local path available (got: #{result.inspect})" unless final_path
      
      final_path
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
      
      # Add reply-to information if original message exists
      reply_to = nil
      if msg.respond_to?(:id)
        reply_to = msg.id
      elsif msg.respond_to?(:message_id)
        reply_to = msg.message_id
      end
      
      dlog "[TD_SEND_MESSAGE] reply_to=#{reply_to} msg.class=#{msg.class}"
      
      if t.in? %w[message text]
        begin
          result = message_sender.send_text(msg.chat.id, text, parse_mode: parse_mode, reply_to: reply_to)
        rescue => e
          dlog "[TD_SEND_TEXT_ERROR] #{e.class}: #{e.message}"
          # Fallback: try without reply_to
          result = message_sender.send_text(msg.chat.id, text, parse_mode: parse_mode, reply_to: nil)
        end
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
    rescue => e
      dlog "[TD_SEND_ERROR] #{e.class}: #{e.message}"
      SymMash.new(message_id: 0, text: text)
    end

    def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params)
      message_sender.edit_message(msg.chat.id, id, text, parse_mode: parse_mode)
    end

    def delete_message(msg, id, wait: nil)
      message_sender.delete_message(msg.chat.id, id)
      dlog "[TD_DELETE] wait=#{wait}"
    end

    def mark_read(msg)
      client.view_messages(chat_id: msg.chat_id, message_ids: [msg.id], source: nil, force_read: true)
      dlog "[READ] chat=#{msg.chat_id} id=#{msg.id}"
    rescue => e
      dlog "[READ_ERROR] #{e.class}: #{e.message}"
    end

    # Legacy compatibility method for direct editing
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
  end
end