require 'tdlib-ruby'
require 'set'
require 'fileutils'
require 'limiter'
require 'retriable'
require_relative 'base'
require_relative 'rate_limiter'

module Bot
  class TDBot < Base
    include TD::Logging
    include RateLimiter

    class_attribute :cthread, :td, :message_handler, :message_sender, :file_manager
    self.max_caption = 4096

    TD::Client.configure_for_bot
    self.td = TD::Client.new timeout: 1.minute
    self.message_handler = TD::MessageHandler.new(td)
    self.message_sender  = TD::MessageSender.new(td)
    self.file_manager    = TD::FileManager.new(td)
    td.setup_authentication_handlers

    def self.start(manager, &block)
      ENV['CUDA'] = '1'
      Bot::UserQueue.queue_size = 3
      self.cthread = Thread.new do
        trap(:INT){ self.td.connect } # cause crash
        at_exit{ self.td.connect }
        td.connect
      end
      bot = self.new
      manager.start_bot_service
      bot.listen do |msg|
        Thread.new{ block.call(msg) }
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
      Bot::MsgHelpers::MARKDOWN_FORMAT.each { |c| text = text.gsub(c, "\\#{c}") }
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
        p[:thumb] = media[:thumb_path] || media[:thumb]
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
      dlog "[TD_ERROR] #{e.class}: #{e.message}"
      nil
    rescue => e
      dlog "[TD_ERROR] #{e.class}: #{e.message}"
      nil
    end
  end
end

