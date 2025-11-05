require_relative 'boot'

require 'active_support/all'
require 'tmpdir'
require 'shellwords'
require 'rack/mime'
require 'mechanize'
require 'roda'
require 'drb/drb'
require 'retriable'
require 'ostruct'

require 'srt'
require 'iso-639'

require_relative 'exts/sym_mash'
require_relative 'exts/peach'

require_relative 'zipper'
require_relative 'prober'
require_relative 'utils/sh'
require_relative 'subtitler'
require_relative 'tagger'
require_relative 'translator'
require_relative 'msg_helpers'
require_relative 'ocr'
require_relative 'audiobook'
require_relative 'downloaders'

require_relative 'bot/status'
require_relative 'utils/url_shortener'
require_relative 'processors/base'
require_relative 'processors/media'
require_relative 'processors/audio'
require_relative 'processors/video'
require_relative 'processors/document'
require_relative 'processors/shorts'
require_relative 'processors/url'
require_relative 'bot/worker'
require_relative 'bot/user_queue'
require_relative 'bot/commands/cookie'

# deprecated behavior
 ActiveSupport.to_time_preserves_timezone = :zone

if ENV['DB']
  require 'sequel'
  require_relative 'sequel'
  require_relative 'models/session' if !$0.index('sequel') and DB
end

class Manager

  attr_reader :bot

  def initialize
    @user_queue = Bot::UserQueue.new
  end

  def self.http
    Thread.current[:manager_http] ||= Mechanize.new.tap do |a|
      t = ENV['HTTP_TIMEOUT']&.to_i || 30.minutes
      a.open_timeout = t; a.read_timeout = t
    end
  end

  def mock_start
    require_relative 'tl_bot'
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
    require_relative 'td_bot'
    DRb.start_service ENV['DRB_WORKER_TD'], self rescue nil

    ENV['CUDA'] = '1' #faster and don't work with maxrate for limiting
    Zipper.size_mb_limit = 2_000
    Bot::UserQueue.queue_size = 3
    @bot = TDBot.connect
    @bot.listen do |msg|
      Thread.new{ react msg }
    end
    sleep 1.year while true
  end

  def start_tl_bot
    require_relative 'tl_bot'

    Zipper.size_mb_limit = 50
    Bot::UserQueue.queue_size = 1
    @bot = TlBot.connect
    @bot.listen do |msg|
      next unless msg.is_a? Telegram::Bot::Types::Message
      fork msg.text do
        react SymMash.new(msg.to_h)
      end
      Thread.new{ sleep 1 and abort } if @exit # wait for other msg processing and trigger systemd restart
    end
  end

  def td_bot?
    defined?(TDBot) && bot.is_a?(TDBot)
  end

  def send_help msg
    msg.bot.send_message msg, bot.mnfe(START_MSG)
  end

  BLOCKED_USERS = ENV['BLOCKED_USERS'].split.map(&:to_i)

  def react msg
    msg.bot = bot
    return if msg.text.blank? && msg.video.blank? && msg.audio.blank? && msg.document.blank?
    return send_help msg if msg.text&.starts_with? '/start'
    return send_help msg if msg.text&.starts_with? '/help'
    raise 'user blocked' if msg.from.id.in? BLOCKED_USERS

    return Manager::Commands::Cookie.new(bot, msg).process if msg.text&.starts_with? '/cookie'

    download msg
  rescue => e
    report_error msg, e rescue nil
    raise
  end

  def download msg
    msg = SymMash.new(msg.to_h).tap { |m| m.bot ||= bot }
    worker = Bot::Worker.new(msg.bot, msg)

    @user_queue.wait_for_slot(msg.from.id, msg) { |text| worker.wait_in_queue(text) } unless MsgHelpers.from_admin?(msg)
    resp = worker.process
  ensure
    msg.bot.delete_message(msg, resp.message_id, wait: nil) if resp
    @user_queue.release_slot(msg.from.id) { |next_msg| download(next_msg) }
  end

end


