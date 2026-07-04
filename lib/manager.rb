require_relative 'boot'

require 'tmpdir'
require 'mechanize'
require 'roda'
require 'retriable'
require 'ostruct'

require_relative 'bot/user_queue'
require_relative 'bot/base'
require_relative 'bot/commands/cookie'
require_relative 'bot/worker/drb_service'
require_relative 'bot/worker/http_service'
require_relative 'utils/input_parser'

require_relative 'worker' if ENV['WITH_WORKER']
require_relative 'bot/tg_bot' if ENV['TG_BOT']
require_relative 'bot/td_bot' if ENV['TD_BOT']

if ENV['DB']
  require 'sequel'
  require_relative 'sequel'
  require_relative 'models/session' if !$0.index('sequel') and DB
end

class Manager

  START_MSG = <<-EOS
Download and convert videos/audios from Youtube, Facebook, Instagram, etc.
Options:
- Use `audio` keyword after link to extract audio
- Use `caption` to put title and uploader
- Use `number` to add the number for each file in playlists

Report issues at https://github.com/brauliobo/media-downloader-bot/issues/new

Examples:
https://youtu.be/FtGEzUKcAnE
https://youtu.be/n8TOOEXsrLw audio caption
https://www.instagram.com/p/CTAXxxODblP/
https://web.facebook.com/groups/590968084832296/posts/920964005166034 audio
https://soundcloud.com/br-ulio-bhavamitra/sets/didi-gunamrta caption number
EOS

  # Simple retry helper with Telegram-aware sleep.
  # Yields the current attempt index (0 for first call) to the block.
  # Customization via kwargs: :tries, :base_interval, :multiplier, :on, :max_interval,
  # :randomization_factor, :retry_after_extractor (-> ex { seconds.to_f }), :on_retry (hook).
  def self.retriable(**opts)
    defaults = { tries: 3, base_interval: 0.3, multiplier: 2.0, on: [StandardError] }
    user_on_retry = opts.delete(:on_retry)
    retry_after_extractor = opts.delete(:retry_after_extractor) || ->(ex){
      m = ex.message.to_s[/retry after (\d+(?:\.\d+)?)/, 1] rescue nil
      m ? m.to_f : 0.0
    }

    attempt = 0
    Retriable.retriable(**defaults.merge(opts), on_retry: ->(ex, try, elapsed, next_interval) do
      ra = begin retry_after_extractor.call(ex).to_f rescue 0 end
      sleep ra if ra > 0
      attempt = try + 1
      user_on_retry&.call(ex, try, elapsed, next_interval)
    end) do
      yield(attempt)
    end
  end

  attr_reader :bot
  attr_reader :queue

  def initialize
    @queue = Queue.new
  end

  def self.http
    Utils::HTTP.client
  end

  def mock_start
    @bot = Bot::Mock.new
  end

  def start
    start_td_bot if ENV['TD_BOT']
    start_tg_bot if ENV['TG_BOT']
    start_bot_service
    sleep 1.year while true
  end

  def start_td_bot
    @bot = Bot::TDBot.start{ |msg| react msg }
  end

  def start_tg_bot
    @bot = Bot::TgBot.start{ |msg| react msg }
  end

  def send_help msg
    msg.bot.send_message msg, Bot::MsgHelpers.mnfe(START_MSG)
  end

  BLOCKED_USERS = ENV['BLOCKED_USERS'].to_s.split(/[\s,]+/).reject(&:empty?).map(&:to_i)

  def react msg
    msg.bot = bot
    msg.bot_type = bot.class.name
    return if msg.respond_to?(:is_outgoing) && msg.is_outgoing
    return if msg.text.blank? && msg.video.blank? && msg.audio.blank? && msg.document.blank?
    return send_help msg if msg.text&.starts_with? '/start'
    return send_help msg if msg.text&.starts_with? '/help'
    raise 'user blocked' if msg.from.id.in? BLOCKED_USERS

    cmd_text = Utils::InputParser.message_text(msg).presence
    return Commands::Cookie.new(bot, msg).process if cmd_text&.starts_with?('/cookies') || (msg.document&.file_name&.downcase == 'cookies.txt')

    enqueue_message msg
  rescue => e
    bot.report_error msg, e rescue nil
    STDERR.puts e.full_message
    raise
  end

  def enqueue_message(msg)
    if ENV['WITH_WORKER']
      Worker.service = bot
      worker = Worker.new msg
      worker.process
    else
      @queue.enq msg
    end
  end

  def dequeue(timeout: nil)
    @queue.deq(timeout: timeout)
  end

  def queue_size
    @queue.size
  end

  def start_bot_service
    if ENV['BOT_HTTP']
      uri = URI.parse(ENV['BOT_HTTP'])
      port = uri.port || 8080
      host = uri.host.presence || ENV['BOT_HTTP_BIND'].presence || '127.0.0.1'
      Bot::Worker::HTTPService.start(self, port, host: host)
    end

    Bot::Worker::DRbService.start(self, ENV['BOT_DRB']) if ENV['BOT_DRB']
  end

  def bot_service_uri
    ENV['BOT_HTTP'] || ENV['BOT_DRB']
  end

  def max_caption
    bot.max_caption
  end

  def find_chats(...)
    bot.find_chats(...)
  end

  def chat_messages(...)
    bot.chat_messages(...)
  end

  def chat_message(...)
    bot.chat_message(...)
  end

  def edit_generated_message(...)
    bot.edit_generated_message(...)
  end

  def upload_generated_media(...)
    bot.upload_generated_media(...)
  end

  def send_message(msg:, text:, **params)
    drb_result bot.send_message(msg, text, **params)
  end

  def send_album(msg:, text:, uploads:, **params)
    uploads = Array(uploads).map { |upload| upload.is_a?(Hash) ? SymMash.new(upload) : upload }
    Array(bot.send_album(msg, text, uploads: uploads, **params)).map { |result| drb_message_result(result) }
  rescue => e
    raise RuntimeError, drb_error_message(e)
  end

  def edit_message(msg:, id:, **params)
    drb_result bot.edit_message(msg, id, **params)
  end

  def delete_message(msg:, id:, **params)
    bot.delete_message(msg, id, **params)
    true
  end

  def report_error(msg:, e:, error_class: nil, context: nil)
    error = StandardError.new(e)
    error.define_singleton_method(:class) { OpenStruct.new(name: error_class) } if error_class
    bot.report_error(msg, error, context: context)
    true
  end

  def download_file(...)
    bot.download_file(...)
  end

  private

  def drb_result(result)
    result.respond_to?(:to_h) ? result.to_h : result
  end

  def drb_message_result(result)
    {
      message_id:     result.respond_to?(:message_id) ? result.message_id : nil,
      id:             result.respond_to?(:id) ? result.id : nil,
      media_group_id: result.respond_to?(:media_group_id) ? result.media_group_id : nil,
    }.compact
  end

  def drb_error_message(error)
    message = "#{error.class}: #{error.message}"
    body    = error.respond_to?(:response) && error.response.respond_to?(:body) ? error.response.body : nil
    body.present? ? "#{message}: #{body}" : message
  end

end
