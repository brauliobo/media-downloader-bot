require 'bundler/setup'
require 'active_support/all'
require 'dotenv'
require 'telegram/bot'
Dotenv.load! '.env'

require 'tmpdir'
require 'shellwords'
require 'rack/mime'
require 'mechanize'
require 'pry' rescue nil # fails with systemd

require_relative 'exts/sym_mash'
require_relative 'exts/peach'

require_relative 'bot/helpers'
require_relative 'bot/zipper'
require_relative 'bot/url_shortner'
require_relative 'bot/worker'

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
      start_webserver
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

  def react msg
    return if msg.text.blank? and msg.video.blank? and msg.audio.blank?
    return send_help msg if msg.text&.starts_with? '/start'
    return send_help msg if msg.text&.starts_with? '/help'

    download msg
  rescue => e
    report_error msg, e
  end

  def download msg
    worker = Worker.new self, msg
    resp   = worker.process
  ensure
    delete_message msg, resp.result.message_id, wait: nil if resp
  end

end
