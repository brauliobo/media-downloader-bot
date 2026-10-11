require 'tdlib-ruby'
require 'concurrent/map'
require 'set'
require 'fileutils'

module Bot
  class TDBot < Base
    include TD::Logging
    include RateLimiter
    include AlbumSending

    self.max_caption = 4096
    MEDIA_SEND_TIMEOUT = 1_800
    SEND_OUTCOME_LIMIT = 1_000
    SendOutcome = Struct.new(:message_id, :error, keyword_init: true)

    class_attribute :td
    class_attribute :message_handler, :message_sender, :file_manager, :message_send_outcomes, :status_jobs
    TD::Client.configure_for_bot
    self.td = TD::Client.new timeout: nil
    self.message_handler = TD::MessageHandler.new(td)
    message_handler.singleton_class.prepend(::TDBot::MessageTopic)
    message_handler.singleton_class.prepend(::TDBot::MessageAttachments)
    self.message_sender  = TD::MessageSender.new(td)
    self.file_manager    = TD::FileManager.new(td)
    self.message_send_outcomes = Concurrent::Map.new
    self.status_jobs = Concurrent::Map.new
    record_send_outcome = lambda do |message_id, outcome|
      message_send_outcomes.delete(message_send_outcomes.keys.first) if message_send_outcomes.size >= SEND_OUTCOME_LIMIT
      message_send_outcomes[message_id] = outcome
    end
    td.on TD::Types::Update::MessageSendSucceeded do |update|
      record_send_outcome.call(update.old_message_id, SendOutcome.new(message_id: update.message.id))
    end
    td.on TD::Types::Update::MessageSendFailed do |update|
      record_send_outcome.call(update.old_message_id, SendOutcome.new(error: TD::Error.new(update.error)))
    end
    td.setup_authentication_handlers

    def self.start(on_callback: nil, &block)
      ENV['CUDA'] = '1'
      Zipper.size_mb_limit = 2_000

      bot = self.new
      Thread.new{ td.connect }
      bot.listen(on_callback: on_callback) do |msg|
        Thread.new do
          Bot::UserQueue.instance.with_user_slot(bot, msg) { block.call msg }
        rescue => e
          STDERR.puts "td dispatch error: #{e.full_message}"
        end
      end
      bot
    end

    def listen(on_callback: nil, &handler)
      dlog "[LISTEN] waiting for messages..."
      message_handler.setup_handlers(&handler)
      setup_callback_handler(on_callback) if on_callback
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

    def download_file(file_id_or_info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: nil)
      result = file_manager.download_file(
        file_id_or_info, priority: priority, offset: offset, limit: limit,
        synchronous: synchronous, dir: dir
      )
      raise "Failed to download file: #{result[:error]}" if result[:error]

      result[:local_path].presence or raise "Failed to download file: no local path available (got: #{result.inspect})"
    end

    def normalize_params(params, type:)
      p = params.dup
      if type.to_sym == :paid_media
        media      = p.delete(:media).first
        media_type = media[:type].to_sym
        p[:file]      = p.delete(:file_path)
        p[media_type] = media[:media_path]
        p[:thumb]     = media.values_at(:thumbnail_path, :thumb_path, :thumbnail, :thumb).compact.first
        p.merge!(media.slice(:duration, :width, :height, :title, :performer, :supports_streaming).compact)
      else
        media_type = type.to_sym
        p[media_type] = p.delete(:file_path)
        p.delete(:file_mime)
        p[:thumb] = p.delete(:thumb_path) || p.delete(:thumbnail_path) || p.delete(:thumbnail)
      end
      [media_type, p]
    end

    def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, cancel_job: nil, **params)
      t = type.to_s
      media_type, params = normalize_params(params, type: type) unless t.in?(%w[message text])
      text = media_caption(msg, text, parse_mode) if media_type
      ret = with_rate_limit('send_message') do
        throttle!
        reply_to = incoming_message_id(msg, :id, :message_id)
        dlog "[TD_SEND_MESSAGE] reply_to=#{reply_to} msg.class=#{msg.class}"
        if t.in? %w[message text]
          result = message_sender.send_text(
            msg.chat.id,
            text,
            parse_mode:   parse_mode,
            reply_to:     reply_to,
            reply_markup: job_reply_markup(cancel_job),
          )
        else
          result = message_sender.public_send("send_#{media_type}", msg.chat.id, text, reply_to: reply_to, **params)
          result = wait_for_media_send(result, timeout: params[:timeout].to_i.nonzero? || MEDIA_SEND_TIMEOUT)
        end
        finalize_sent_message(msg, SymMash.new(result), delete: delete, delete_both: delete_both)
      end
      ret ||= SymMash.new(message_id: 0, text: text)
      status_jobs[[msg.chat.id, ret.message_id]] = cancel_job if cancel_job && ret.message_id.to_i.positive?
      ret
    end

    # Buttons are unavailable on TD, so a "/stop" reply to a job's status message cancels only that job.
    # The reply targets the final message id, while the status was tracked under the id returned on send.
    def reply_job_id(msg)
      reply_id = msg.reply_to_message_id
      status_jobs.each_pair.find { |(chat_id, id), _| chat_id == msg.chat.id && [id, message_send_outcomes[id]&.message_id].include?(reply_id) }&.last
    end

    def album_caption(msg, text, parse_mode) = media_caption(msg, text, parse_mode)

    def send_album_batch(msg, batch, parse_mode)
      result = with_rate_limit('send_album') do
        throttle!
        message_sender.send_media_album(msg.chat.id, batch.uploads, caption: batch.caption, parse_mode: parse_mode, timeout: 1_800)
      end
      result ? Array(result.try(:messages) || result) : send_album_items(msg, batch, parse_mode)
    rescue TD::Error => e
      raise unless e.message.to_s.include?('InputFile is not specified')

      send_album_items(msg, batch, parse_mode)
    end

    def media_caption(msg, text, parse_mode)
      Caption.prepare(text, parse_mode: parse_mode) { |full| send_message(msg, full, parse_mode: parse_mode) }
    end

    def send_album_items(msg, batch, parse_mode)
      batch.items.map do |up, caption|
        with_rate_limit('send_album_item') do
          throttle!
          case Utils::MimeTypes.telegram_type(up)
          when :video
            message_sender.send_video(msg.chat.id, caption, video: up.fn_out, reply_to: nil)
          when :photo
            message_sender.send_photo(msg.chat.id, caption, photo: up.fn_out, parse_mode: parse_mode, reply_to: nil, timeout: 1_800)
          else
            message_sender.send_document(msg.chat.id, caption, document: up.fn_out, reply_to: nil)
          end
        end
      end
    end

    def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', force: false, cancel_job: nil, **params)
      reply_markup = job_reply_markup(cancel_job)
      status_jobs.delete([msg.chat.id, id]) if cancel_job == false
      throttle_edit(msg.chat.id, id, force: force) do
        with_rate_limit('edit_message') do
          message_sender.edit_message(msg.chat.id, id, text, parse_mode: parse_mode, reply_markup: reply_markup)
          true
        end || false
      end
    end

    delegate :edit_generated_message, :upload_generated_media, :ensure_forum_topic, :find_chats,
             :resolve_chat_identifier, :chat_messages, :chat_message, :list_chats, :forum_topics, :copy_message,
             :incoming_message, :message_link, :leave_chat, to: :post_editor

    def post_editor
      @post_editor ||= ::TDBot::PostEditor.new(self)
    end

    def perform_delete_message(msg, id)
      result = message_sender.delete_message_public(msg.chat.id, id)
      dlog "[TD_DELETE] result=#{result ? 'success' : 'failed'}"
      result
    end

    def answer_callback(callback, text: nil)
      td.answer_callback_query(
        callback_query_id: callback.id,
        text:              text.to_s,
        show_alert:        false,
        url:               '',
        cache_time:        0,
      ).value(15)
    rescue TD::Error
      nil
    end

    def edit(msg, text)
      edit_message(msg, msg.id, text: text)
    end

    def with_rate_limit(tag, &block)
      super
    rescue TD::Error => e
      STDERR.puts "[TD_ERROR] #{e.class}: #{e.message}"
      dlog "[TD_ERROR] #{e.class}: #{e.message}"
      raise
    rescue => e
      STDERR.puts "[TD_ERROR] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      dlog "[TD_ERROR] #{e.class}: #{e.message}"
      raise
    end

    private

    def setup_callback_handler(handler)
      td.on TD::Types::Update::NewCallbackQuery do |query|
        next unless query.payload.is_a?(TD::Types::CallbackQueryPayload::Data)

        callback = Bot::Callback.new(
          id:         query.id,
          user_id:    query.sender_user_id,
          chat_id:    query.chat_id,
          message_id: query.message_id,
          data:       query.payload.data,
        )
        Thread.new do
          handler.call(callback)
        rescue => e
          STDERR.puts "td callback error: #{e.full_message}"
        end
      end
    end

    def job_reply_markup(_job_id)
      nil
    end

    def wait_for_media_send(result, timeout:)
      response   = SymMash.new(result)
      message_id = response.message_id.to_i
      raise 'TDLib failed to queue media message' unless message_id.positive?

      deadline = Time.now + timeout
      loop do
        if (outcome = self.class.message_send_outcomes.delete(message_id))
          raise outcome.error if outcome.error

          response.message_id = outcome.message_id
          return response
        end

        raise "timed out waiting for media message #{message_id}" if Time.now >= deadline
        sleep 0.1
      end
    end
  end
end
