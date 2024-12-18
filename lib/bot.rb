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

require_relative 'bot/status'
require_relative 'bot/url_shortner'
require_relative 'bot/processor'
require_relative 'bot/file_processor'
require_relative 'bot/url_processor'
require_relative 'bot/worker'

if ENV['DB']
  require 'sequel'
  require_relative 'sequel'
  require_relative 'bot/session' if !$0.index('sequel') and DB
end

class Bot

  attr_reader :bot

  def initialize
  end

  def mock_start
    TlBot.mock
    @bot = Bot.new nil
  end

  def fork name
    Kernel.fork do
      DB.disconnect if defined? DB
      Process.setproctitle name
      yield
    end
  end

  def start
    fork('tdlib'){ start_td_bot }
    fork('tlbot'){ start_tl_bot }
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
    return if ENV['SKIP_TDBOT']
    require_relative 'td_bot'
    DRb.start_service ENV['DRB_WORKER_TD'], self

    @bot = TDBot.connect
    @bot.listen do |msg|
      Thread.new do
        react msg
      end
    end
    sleep 1.year while true
  end

  def start_tl_bot
    return if ENV['SKIP_BOT']
    require_relative 'tl_bot'
    @bot = TlBot.connect
    @bot.listen do |msg|
      Thread.new do
        next unless msg.is_a? Telegram::Bot::Types::Message
        react SymMash.new(msg.to_h)
      end
      Thread.new{ sleep 1 and abort } if @exit # wait for other msg processing and trigger systemd restart
    end
  end

  def send_help msg
    msg.bot.send_message msg, mnfe(START_MSG)
  end

  BLOCKED_USERS = ENV['BLOCKED_USERS'].split.map(&:to_i)

  def react msg
    msg.bot = bot
    return if msg.text.blank? and msg.video.blank? and msg.audio.blank?
    return send_help msg if msg.text&.starts_with? '/start'
    return send_help msg if msg.text&.starts_with? '/help'
    raise 'user blocked' if msg.from.id.in? BLOCKED_USERS

    download msg
  rescue => e
    report_error msg, e rescue nil
  end

  def download msg
    msg    = SymMash.new msg.to_h
    worker = Worker.new msg.bot, msg
    resp   = worker.process
  ensure
    msg.bot.delete_message msg, resp.message_id, wait: nil if resp
  end

end
