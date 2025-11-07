require 'telegram/bot'
require 'puma'
require 'roda'
require 'limiter'
require_relative 'bot/base'
require_relative 'bot/rate_limiter'
require_relative 'msg_helpers'

class TgBot < Bot::Base
  include MsgHelpers
  include Bot::RateLimiter

  RETRY_ERRORS = [
    Faraday::ConnectionFailed,
    Faraday::TimeoutError,
    Net::OpenTimeout, Net::WriteTimeout,
  ]

  self.error_delete_time = 3.hours
  self.max_caption = 1024

  class_attribute :tg
  delegate_missing_to :tg

  def initialize(tg)
    self.tg = tg
  end

  def self.start(manager, &block)
    Bot::UserQueue.queue_size = 1
    bot = nil
    Telegram::Bot::Client.run ENV['TG_BOT_TOKEN'], logger: Logger.new(STDOUT) do |tg_bot|
      puts 'bot: started, listening'
      bot = new(tg_bot) unless bot
      manager.start_bot_service
      tg_bot.listen do |msg|
        next unless msg.is_a? Telegram::Bot::Types::Message
        Thread.new do
          block.call SymMash.new msg.to_h
        end
      end
    end
    bot
  end

  def tg_text_payload(msg, text, parse_mode)
    t = parse_text text, parse_mode: parse_mode
    { chat_id: msg.chat.id, text: t, caption: t, parse_mode: parse_mode }
  end

  def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params)
    return if throttle!(msg.chat.id, :low, discard: true, message_id: id) == :discard
    tg.send "edit_message_#{type}", **tg_text_payload(msg, text, parse_mode), message_id: id, **params
  rescue ::Telegram::Bot::Exceptions::ResponseError => e
    resp = SymMash.new(JSON.parse(e.response.body))
    return if resp&.description&.match(/exactly the same as a current content/)
    raise
  end

  class ::Telegram::Bot::Types::Message
    attr_accessor :resp
  end

  def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
    _text = text
    throttle! msg.chat.id, :high
    ep = "send_#{type}"
    payload = tg_text_payload(msg, text, parse_mode)
    payload.delete(:text) if type.to_s != 'message'
    payload[:reply_to_message_id] = msg.message_id
    resp  = SymMash.new tg.send(ep, **payload, **wrap_upload_params(params)).to_h
    resp.text = _text

    delete = delete_both if delete_both
    delete_message msg, resp.message_id, wait: delete if delete
    delete_message msg, msg.message_id, wait: delete_both if delete_both

    resp
  end

  def wrap_upload_params(p)
    p = p.dup
    if p[:type].to_s == 'paid_media' && p[:file_path]
      p[:file] = build_upload_io(p.delete(:file_path), p.delete(:file_mime))
    end
    %i[audio video document].each do |k|
      kp = :"#{k}_path"
      km = :"#{k}_mime"
      p[k] = build_upload_io(p.delete(kp), p.delete(km)) if p[kp]
    end
    p[:thumb] = build_upload_io(p.delete(:thumb_path), 'image/jpeg') if p[:thumb_path]
    p[:thumbnail] = build_upload_io(p.delete(:thumbnail_path), 'image/jpeg') if p[:thumbnail_path]
    p
  end

  def build_upload_io(path, mime=nil)
    return unless path
    mime ||= Rack::Mime.mime_type(File.extname(path)) || 'application/octet-stream'
    Faraday::UploadIO.new(path, mime)
  end

  def delete_message(msg, id, wait: 30.seconds)
    Thread.new do
      sleep wait if wait
    ensure
      tg.delete_message chat_id: msg.chat.id, message_id: id
    end
  end


  def download_file(info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: Dir.pwd)
    tg_path   = tg.get_file(file_id: info.file_id).file_path or raise 'no file_path returned'
    file_name = info.respond_to?(:file_name) && info.file_name.present? ? info.file_name : File.basename(tg_path)
    local     = File.join dir, file_name

    base_url = "https://api.telegram.org/file/bot#{ENV['TG_BOT_TOKEN']}/"
    File.write local, Mechanize.new.get(base_url + tg_path).body
    local
  end
end
