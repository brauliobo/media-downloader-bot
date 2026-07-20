require 'telegram/bot'
require 'puma'
require 'roda'
require_relative 'base'
require_relative 'jobs'
require_relative 'rate_limiter'
require_relative '../utils/safety'

module Bot
  class TgBot < Base
    include RateLimiter

    RETRY_ERRORS = [
      Faraday::ConnectionFailed,
      Faraday::TimeoutError,
      Net::OpenTimeout, Net::WriteTimeout,
    ]

    self.error_delete_time = 3.hours
    self.max_caption = 1024

    class_attribute :tg
    delegate_missing_to :tg

    def self.start(on_callback: nil, &block)
      Zipper.size_mb_limit = 50
      bot = new
      Thread.new do
        Telegram::Bot::Client.run ENV['TG_BOT_TOKEN'], logger: Logger.new(STDOUT) do |tg_bot|
          puts 'bot: started, listening'
          bot.tg = tg_bot.api
          tg_bot.listen do |msg|
            if msg.is_a?(Telegram::Bot::Types::CallbackQuery)
              Thread.new do
                on_callback&.call(callback_from(msg))
              rescue => e
                STDERR.puts "tg callback error: #{e.full_message}"
              end
              next
            end
            next unless msg.is_a?(Telegram::Bot::Types::Message)
            Thread.new do
              sym_msg = SymMash.new msg.to_h
              Bot::UserQueue.instance.with_user_slot(bot, sym_msg) do
                dispatch_message(sym_msg, &block)
              end
            rescue => e
              STDERR.puts "tg dispatch error: #{e.full_message}"
            end
          end
        end
      end
      bot
    end

    def self.callback_from(query)
      Bot::Callback.new(
        id:         query.id,
        user_id:    query.from.id,
        chat_id:    query.message&.chat&.id,
        message_id: query.message&.message_id,
        data:       query.data,
      )
    end

    def self.dispatch_message(msg, &block)
      block.call msg
    end

    def tg_text_payload(msg, text, parse_mode)
      t = parse_text text, parse_mode: parse_mode
      { chat_id: msg.chat.id, text: t, caption: t, parse_mode: parse_mode }
    end

    def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', force: false, cancel_job: nil, **params)
      throttle_edit(msg.chat.id, id, force: force) do
        params[:reply_markup] = job_reply_markup(cancel_job) unless cancel_job.nil?
        tg.send "edit_message_#{type}", **tg_text_payload(msg, text, parse_mode), message_id: id, **params
      rescue ::Telegram::Bot::Exceptions::ResponseError => e
        resp = SymMash.new(JSON.parse(e.response.body))
        next if resp&.description&.match(/exactly the same as a current content/)
        raise
      end
    end

    class ::Telegram::Bot::Types::Message
      attr_accessor :resp
    end

    def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, cancel_job: nil, **params)
      _text = text
      throttle!
      ep = "send_#{type}"
      payload = tg_text_payload(msg, text, parse_mode)
      payload.delete(:text) if type.to_s != 'message'
      payload[:reply_to_message_id] = incoming_message_id(msg)
      params[:reply_markup] = job_reply_markup(cancel_job) unless cancel_job.nil?
      resp  = SymMash.new tg.send(ep, **payload, **wrap_upload_params(params.merge(type: type))).to_h
      resp.text = _text

      finalize_sent_message(msg, resp, delete: delete, delete_both: delete_both)
    end

    def send_album(msg, text, uploads:, parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **_params)
      sent  = []
      first = true

      uploads.each_slice(10) do |batch|
        throttle!
        payload = {
          chat_id:             msg.chat.id,
          reply_to_message_id: incoming_message_id(msg),
          media:               album_media(batch, first ? text : nil, parse_mode)
        }
        batch.each_with_index { |up, i| payload["file#{i}".to_sym] = build_upload_io(up.fn_out, up.mime) }
        first = false
        sent.concat Array(tg.send(:send_media_group, **payload).map { |m| SymMash.new(m.to_h) })
      end

      finalize_sent_message(msg, sent.first || SymMash.new(message_id: 0), delete: delete, delete_both: delete_both)
      sent
    rescue => e
      raise RuntimeError, telegram_response_error_message(e)
    end

    def wrap_upload_params(p)
      p = p.dup
      type = p.delete(:type)
      if type.to_s == 'paid_media'
        p[:file] = build_upload_io(p.delete(:file_path), p.delete(:file_mime))
        if (media = Array(p[:media]).first) && (path = pop_thumbnail_path(media))
          media[:thumbnail] = 'attach://thumbnail'
          p[:thumbnail] = build_upload_io(path, 'image/jpeg')
        end
      elsif p.key?(:file_path)
        media_type = type.to_sym
        p[media_type] = build_upload_io(p.delete(:file_path), p.delete(:file_mime))
      end
      thumb_path     = p.delete(:thumb_path)
      thumbnail_path = p.delete(:thumbnail_path) || thumb_path
      p[:thumb]      = build_upload_io(thumb_path, 'image/jpeg') if thumb_path
      p[:thumbnail]  = build_upload_io(thumbnail_path, 'image/jpeg') if thumbnail_path
      p
    end

    def pop_thumbnail_path(params)
      params.delete(:thumbnail_path) || params.delete(:thumb_path) || params.delete(:thumbnail) || params.delete(:thumb)
    end

    def build_upload_io(path, mime=nil)
      return unless path
      mime ||= Rack::Mime.mime_type(File.extname(path)) || 'application/octet-stream'
      Faraday::UploadIO.new(path, mime)
    end

    def album_media(batch, caption, parse_mode)
      batch.map.with_index do |up, i|
        media = { type: Utils::MimeTypes.telegram_type(up.mime), media: "attach://file#{i}" }
        if i.zero? && caption.present?
          media[:caption] = parse_text(caption, parse_mode: parse_mode)
          media[:parse_mode] = parse_mode
        end
        media
      end.to_json
    end

    def telegram_response_error_message(error)
      body = error.respond_to?(:response) && error.response.respond_to?(:body) ? error.response.body : nil
      body.present? ? "#{error.class}: #{error.message}: #{body}" : "#{error.class}: #{error.message}"
    end

    def answer_callback(callback, text: nil)
      tg.answer_callback_query(callback_query_id: callback.id, text: text)
    end

    def fork_workers?
      true
    end

    def perform_delete_message(msg, id)
      tg.delete_message chat_id: msg.chat.id, message_id: id
    end

    def job_reply_markup(job_id)
      buttons = if job_id == false
        []
      else
        [[Telegram::Bot::Types::InlineKeyboardButton.new(
          text:          'Cancel',
          callback_data: Bot::Jobs.cancel_data(job_id),
        )]]
      end

      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
    end


    def download_file(info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: Dir.pwd)
      info    = SymMash.new(info) if info.is_a?(Hash)
      file_id = info.respond_to?(:file_id) ? info.file_id : info.to_s
      tg_path = tg.get_file(file_id: file_id).file_path or raise 'no file_path returned'
      name    = info.respond_to?(:file_name) && info.file_name.present? ? info.file_name : File.basename(tg_path)
      local   = Utils::Safety.contained_path(dir, name, fallback: File.basename(tg_path))

      base_url = "https://api.telegram.org/file/bot#{ENV['TG_BOT_TOKEN']}/"
      agent    = Mechanize.new
      agent.redirect_ok = false if agent.respond_to?(:redirect_ok=)
      Utils::Safety.write_exclusive(local, agent.get(base_url + tg_path).body)
      local
    end
  end
end
