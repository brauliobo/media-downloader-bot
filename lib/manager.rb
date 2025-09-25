require 'bundler/setup'
Dir.chdir __dir__ do
  require 'dotenv'
  Dotenv.load  '../.env.user'
  Dotenv.load! '../.env'
end

require 'pry' rescue nil # fails with systemd

require 'active_support/all'
require 'tmpdir'
require 'shellwords'
require 'rack/mime'
require 'mechanize'
require 'roda'
require 'drb/drb'

require 'srt'
require 'iso-639'

require_relative 'exts/sym_mash'
require_relative 'exts/peach'

require_relative 'zipper'
require_relative 'prober'
require_relative 'sh'
require_relative 'subtitler'
require_relative 'tagger'
require_relative 'translator'
require_relative 'msg_helpers'
require_relative 'ocr'

require_relative 'bot/status'
require_relative 'bot/url_shortner'
require_relative 'bot/processor'
require_relative 'bot/file_processor'
require_relative 'bot/document_processor'
require_relative 'bot/url_processor'
require_relative 'bot/worker'

# deprecated behavior
 ActiveSupport.to_time_preserves_timezone = :zone

if ENV['DB']
  require 'sequel'
  require_relative 'sequel'
  require_relative 'bot/session' if !$0.index('sequel') and DB
end

class Manager

  attr_reader :bot

  def initialize
  end

  def self.http
    @http ||= Mechanize.new.tap do |a|
      t = ENV['HTTP_TIMEOUT']&.to_i || 30.min
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
    daemon('tdlib'){ start_td_bot } unless ENV['SKIP_TD_BOT']
    daemon('tlbot'){ start_tl_bot } unless ENV['SKIP_TL_BOT']
    sleep 1.year while true
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
    @bot = TDBot.connect
    # Set up listener; unread processing is handled inside listen/authorization READY
    @bot.listen do |msg|
      react msg # threading now handled in MessageHandler
    end
    sleep 1.year while true
  end

  def start_tl_bot
    require_relative 'tl_bot'

    Zipper.size_mb_limit = 50
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

    download msg
  rescue => e
    report_error msg, e rescue nil
    raise
  end

  def download msg
    msg    = SymMash.new msg.to_h
    worker = Manager::Worker.new msg.bot, msg
    resp   = worker.process
  ensure
    msg.bot.delete_message msg, resp.message_id, wait: nil if resp
  end

end


