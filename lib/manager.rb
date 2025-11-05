require_relative 'boot'

require 'tmpdir'
require 'shellwords'
require 'mechanize'
require 'roda'
require 'retriable'
require 'ostruct'

require_relative 'bot/user_queue'
require_relative 'bot/commands/cookie'
require_relative 'bot/worker/drb_service'
require_relative 'bot/worker/http_service'

require_relative 'worker' if ENV['WITH_WORKER']
require_relative 'utils/http'
require_relative 'tl_bot'
require_relative 'td_bot'

if ENV['DB']
  require 'sequel'
  require_relative 'sequel'
  require_relative 'models/session' if !$0.index('sequel') and DB
end

class Manager

  attr_reader :bot
  attr_reader :queue

  def initialize
    @user_queue = Bot::UserQueue.new
    @queue = Queue.new
  end

  def self.http
    Utils::HTTP.client
  end

  def mock_start
    TlBot.mock
    @bot = TlBot.new self
  end

  def fork name
    pid = Kernel.fork do
      DB.disconnect if defined? DB
      Process.setproctitle name.to_s
      yield
    end
    Process.detach pid
    pid
  end

  def daemon name, &block
    Thread.new do
      loop do
        puts "#{name}: starting"
        pid = self.fork name, &block
        Process.wait pid
      end
    end
  end

  def start
    daemon('tdlib'){ start_td_bot } if ENV['TD_BOT']
    daemon('tlbot'){ start_tl_bot } unless ENV['SKIP_TL_BOT']
    sleep 1.year while true
  end

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

  def start_td_bot
    DRb.start_service ENV['DRB_WORKER_TD'], self rescue nil

    ENV['CUDA'] = '1' #faster and don't work with maxrate for limiting
    Bot::UserQueue.queue_size = 3
    @bot = TDBot.connect
    start_bot_service
    @bot.listen do |msg|
      Thread.new{ react msg }
    end
    sleep 1.year while true
  end

  def start_tl_bot
    Bot::UserQueue.queue_size = 1
    @bot = TlBot.connect
    start_bot_service
    @bot.listen do |msg|
      next unless msg.is_a? Telegram::Bot::Types::Message
      fork msg.text do
        react SymMash.new(msg.to_h)
      end
      Thread.new{ sleep 1 and abort } if @exit # wait for other msg processing and trigger systemd restart
    end
  end

  def send_help msg
    msg.bot.send_message msg, MsgHelpers.mnfe(START_MSG)
  end

  BLOCKED_USERS = ENV['BLOCKED_USERS'].split.map(&:to_i)

  def react msg
    msg.bot = bot
    return if msg.text.blank? && msg.video.blank? && msg.audio.blank? && msg.document.blank?
    return send_help msg if msg.text&.starts_with? '/start'
    return send_help msg if msg.text&.starts_with? '/help'
    raise 'user blocked' if msg.from.id.in? BLOCKED_USERS

    return Manager::Commands::Cookie.new(bot, msg).process if msg.text&.starts_with? '/cookie'

    enqueue_message msg
  rescue => e
    bot.report_error(msg, e) rescue nil if bot.respond_to?(:report_error)
    raise
  end

  def enqueue_message(msg)
    msg = SymMash.new(msg.to_h).tap { |m| m.bot ||= bot }
    msg.bot_type = bot.class.name
    if ENV['WITH_WORKER']
      Thread.new do
        Worker.service = bot
        worker = Worker.new msg
        worker.process
      rescue => e
        bot.report_error msg, e rescue nil
      end
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
      app_class = Bot::Worker::HTTPService.create(self)
      Thread.new do
        require 'puma'
        server = Puma::Server.new(app_class.freeze.app)
        server.add_tcp_listener('0.0.0.0', port)
        puts "Bot HTTP service started on 0.0.0.0:#{port}"
        server.run
      end
    end

    Bot::Worker::DRbService.start(self, ENV['BOT_DRB']) if ENV['BOT_DRB']
  end

  def bot_service_uri
    ENV['BOT_HTTP'] || ENV['BOT_DRB']
  end

end


