require 'bundler/setup'
require 'active_support/all'
require 'telegram/bot'
Dir.chdir __dir__ do
  require 'dotenv'
  Dotenv.load! '../.env'
end

require 'pry' rescue nil # fails with systemd

require 'tmpdir'
require 'shellwords'
require 'rack/mime'
require 'mechanize'
require 'roda'

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
require_relative 'bot/helpers'
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

require 'whisper.cpp' if ENV['WHISPER']

class Bot

  attr_reader :bot
  delegate :api, to: :bot

  include Helpers
  self.bot_name = 'media_downloader_bot'

  self.error_delete_time = 3.hours

  def initialize token
    @token = token
  end

  def start
    wait_net_up
    Telegram::Bot::Client.run @token, logger: Logger.new(STDOUT) do |bot|
      @bot = bot

      puts 'bot: started, listening'
      #start_webserver
      @bot.listen do |msg|
        Thread.new do
          next unless msg.is_a? Telegram::Bot::Types::Message
          react msg
        end
        Thread.new{ sleep 1 and abort } if @exit # wait for other msg processing and trigger systemd restart
      end
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

  def send_help msg
    send_message msg, mnfe(START_MSG)
  end

  BLOCKED_USERS = ENV['BLOCKED_USERS'].split.map(&:to_i)

  def react msg
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
    worker = Worker.new self, msg
    resp   = worker.process
  ensure
    delete_message msg, resp.message_id, wait: nil if resp
  end

end
