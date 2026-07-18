require 'tdlib-ruby'
require 'set'
require 'fileutils'
require 'limiter'
require 'retriable'
require_relative 'base'
require_relative 'rate_limiter'
require_relative '../td_bot/chat_identifier'
require_relative '../td_bot/post_editor'

module Bot
  class TDBot < Base
    include TD::Logging
    include RateLimiter

    self.max_caption = 4096
    MEDIA_CAPTION_LIMIT = 1024

    class_attribute :td
    class_attribute :message_handler, :message_sender, :file_manager
    TD::Client.configure_for_bot
    self.td = TD::Client.new timeout: 1.minute
    self.message_handler = TD::MessageHandler.new(td)
    self.message_sender  = TD::MessageSender.new(td)
    self.file_manager    = TD::FileManager.new(td)
    td.setup_authentication_handlers

    def self.start &block
      ENV['CUDA'] = '1'
      Zipper.size_mb_limit = 2_000

      bot = self.new
      Thread.new{ td.connect }
      bot.listen do |msg|
        Thread.new do
          Bot::UserQueue.instance.with_user_slot(bot, msg) { block.call msg }
        rescue => e
          STDERR.puts "td dispatch error: #{e.full_message}"
        end
      end
      bot
    end

    def td_retry_after_seconds(e)
      e.message[/retry after (\d+)/, 1]&.to_i || 60
    end

    def listen(&handler)
      dlog "[LISTEN] waiting for messages..."
      message_handler.setup_handlers(&handler)
      if ENV['TDLIB_PROCESS_UNREAD'].to_s == '1'
        Thread.new do
          dlog "[UNREAD_THREAD] starting wait for auth"
          if td.wait_for_ready(timeout: 600)
            message_handler.process_unread_messages
          else
            dlog "[UNREAD_THREAD] timeout waiting for auth"
          end
        end
      else
        dlog "[UNREAD_KICK] skipped (TDLIB_PROCESS_UNREAD!=1)"
      end
    end

    def me(text)
      return text unless text
      text = text.gsub('\\', '\\\\')
      text.gsub('`', '\\`')
    end
    alias_method :mnfe, :me

    def mfe(text)
      return text unless text
      MsgHelpers::MARKDOWN_FORMAT.each { |c| text = text.gsub(c, "\\#{c}") }
      text
    end

    def download_file(file_id_or_info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: nil)
      result = file_manager.download_file(
        file_id_or_info, priority: priority, offset: offset, limit: limit,
        synchronous: synchronous, dir: dir
      )
      if result.is_a?(Hash) && result[:error]
        raise "Failed to download file: #{result[:error]}"
      end
      local_path = result.is_a?(Hash) ? result[:local_path] : nil
      unless local_path && !local_path.empty?
        raise "Failed to download file: no local path available (got: #{result.inspect})"
      end
      local_path
    end

    def msg_caption(i)
      return '' if i.respond_to?(:opts) && i.opts.nocaption
      text = ''
      if (i.respond_to?(:opts) && i.opts.caption) || (i.respond_to?(:type) && i.type == Zipper::Types.video)
        text  = "_#{me i.info.title}_"
        text << "\n#{me i.info.uploader}" if i.info.uploader
      end
      if i.respond_to?(:opts) && i.opts.description && i.info.description.strip.presence
        text << "\n\n_#{me i.info.description.strip}_"
      end
      text << "\n\n#{i.url}" if i.url
      text
    end

    def normalize_params(params)
      p = params.dup
      if p[:type] == :paid_media && (media = p.delete(:media)&.first)
        p[:file] = p.delete(:file_path)
        p[media[:type]] = media[:media_path] if media[:type]
        p[:thumb] = media.values_at(:thumbnail_path, :thumb_path, :thumbnail, :thumb).compact.first
        p.merge!(media.slice(:duration, :width, :height, :title, :performer, :supports_streaming).compact)
      else
        %i[audio video document].each { |k| p[k] = p.delete(:"#{k}_path") if p[:"#{k}_path"] }
        p[:thumb] = p.delete(:thumb_path) || p.delete(:thumbnail_path) || p.delete(:thumbnail)
      end
      p
    end

    def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
      t = type.to_s
      params = normalize_params(params) unless t.in?(%w[message text])
      ret = td_with_rate_limit('send_message') do
        throttle! msg.chat.id, :high
        reply_to = incoming_message_id(msg, :id, :message_id)
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
        finalize_sent_message(msg, SymMash.new(result), delete: delete, delete_both: delete_both)
      end
      ret || SymMash.new(message_id: 0, text: text)
    end

    def send_album(msg, text, uploads:, parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **_params)
      sent  = []
      first = true
      text  = album_caption_text(msg, text, parse_mode)

      uploads.each_slice(10) do |batch|
        batch_caption = first ? text : nil
        first = false
        result = td_with_rate_limit('send_album') do
          message_sender.send_media_album(msg.chat.id, batch, caption: batch_caption, parse_mode: parse_mode, timeout: 1_800)
        end
        unless result
          sent.concat send_album_items(msg, batch, batch_caption, parse_mode)
          next
        end
        sent.concat(result.respond_to?(:messages) ? result.messages : Array(result))
      rescue TD::Error => e
        raise unless e.message.to_s.include?('InputFile is not specified')

        sent.concat send_album_items(msg, batch, batch_caption, parse_mode)
      end

      finalize_sent_message(msg, td_message_response(sent.first), delete: delete, delete_both: delete_both)
      sent
    end

    def album_caption_text(msg, text, parse_mode)
      text = td_markdown_caption(text)
      return text if text.size <= MEDIA_CAPTION_LIMIT

      send_message(msg, text, parse_mode: parse_mode)
      truncate_album_caption(text, MEDIA_CAPTION_LIMIT)
    end

    def td_markdown_caption(text)
      MsgHelpers::MARKDOWN_NON_FORMAT.reduce(text.to_s) { |caption, char| caption.gsub("\\#{char}", char) }
    end

    def truncate_album_caption(text, limit)
      suffix = text.to_s[/(?:\n\nhttps?:\/\/\S+)+\z/]
      return truncate_markdown_caption(text, limit) unless suffix && suffix.size < limit

      body = text.to_s.delete_suffix(suffix).rstrip
      [truncate_markdown_caption(body, limit - suffix.size), suffix].join
    end

    def truncate_markdown_caption(text, limit)
      caption = text.to_s.first(limit)
      caption = caption[0...-1] if caption.end_with?('\\')
      return caption unless caption.scan(/(?<!\\)_/).size.odd?

      caption.size < limit ? "#{caption}_" : "#{caption[0...-1]}_"
    end

    def send_album_items(msg, batch, text, parse_mode)
      batch.map.with_index do |up, i|
        caption = i.zero? ? text.to_s : ''
        td_with_rate_limit('send_album_item') do
          if up.mime.to_s.start_with?('video/')
            message_sender.send_video(msg.chat.id, caption, video: up.fn_out, reply_to: nil)
          elsif up.mime.to_s.start_with?('image/')
            message_sender.send_photo(msg.chat.id, caption, photo: up.fn_out, parse_mode: parse_mode, reply_to: nil, timeout: 1_800)
          else
            message_sender.send_document(msg.chat.id, caption, document: up.fn_out, reply_to: nil)
          end
        end
      end
    end

    def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', force: false, **params)
      if force
        td_with_rate_limit('edit_message') do
          Manager.retriable(tries: 3, base_interval: 0.3, multiplier: 2.0) do |_attempt|
            message_sender.edit_message(msg.chat.id, id, text, parse_mode: parse_mode)
            true
          end
        end
      else
        td_with_rate_limit('edit_message') do
          return false if throttle!(msg.chat.id, :low, discard: true, message_id: id) == :discard
          Manager.retriable(tries: 3, base_interval: 0.3, multiplier: 2.0) do |_attempt|
            message_sender.edit_message(msg.chat.id, id, text, parse_mode: parse_mode)
            true
          end
        end || false
      end
    end

    def td_message_response(message)
      id = message[:message_id] || message[:id] if message.is_a?(Hash)
      id ||= message.message_id if message.respond_to?(:message_id)
      id ||= message.id if message.respond_to?(:id)
      SymMash.new(message_id: id || 0, id: id)
    end

    def edit_generated_message(chat_id:, message_id:, text: nil, type: nil, parse_mode: 'MarkdownV2', **params)
      post_editor.edit_generated_message(chat_id: chat_id, message_id: message_id, text: text, type: type, parse_mode: parse_mode, **params)
    end

    def upload_generated_media(chat_id:, text: nil, type:, parse_mode: 'MarkdownV2', **params)
      post_editor.upload_generated_media(chat_id: chat_id, text: text, type: type, parse_mode: parse_mode, **params)
    end

    def find_chats(query, limit: 20, public: false)
      post_editor.find_chats(query, limit: limit, public: public)
    end

    def resolve_chat_identifier(identifier)
      post_editor.resolve_chat_identifier(identifier)
    end

    def chat_messages(chat_id:, limit: 20, query: nil, filter: nil, from_message_id: 0)
      post_editor.chat_messages(chat_id: chat_id, limit: limit, query: query, filter: filter, from_message_id: from_message_id)
    end

    def chat_message(chat_id:, message_id:)
      post_editor.chat_message(chat_id: chat_id, message_id: message_id)
    end

    def post_editor
      @post_editor ||= ::TDBot::PostEditor.new(self)
    end

    def perform_delete_message(msg, id)
      result = message_sender.delete_message_public(msg.chat.id, id)
      dlog "[TD_DELETE] result=#{result ? 'success' : 'failed'}"
      result
    end

    def mark_read(msg)
      td.view_messages(chat_id: msg.chat_id, message_ids: [msg.id], source: nil, force_read: true)
      dlog "[READ] chat=#{msg.chat_id} id=#{msg.id}"
    rescue => e
      dlog "[READ_ERROR] #{e.class}: #{e.message}"
    end

    def edit(msg, text)
      edit_message(msg, msg.id, text: text)
    end

    private

    def td_with_rate_limit(tag)
      return yield
    rescue TD::Error => e
      if e.message.include?('429') || e.message.include?('Too Many Requests')
        ra = td_retry_after_seconds(e); dlog "[RATE_LIMIT] TDLib sleeping #{ra}s (#{tag})"; sleep ra; retry
      end
      STDERR.puts "[TD_ERROR] #{e.class}: #{e.message}"
      dlog "[TD_ERROR] #{e.class}: #{e.message}"
      nil
    rescue => e
      STDERR.puts "[TD_ERROR] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      dlog "[TD_ERROR] #{e.class}: #{e.message}"
      nil
    end
  end
end
