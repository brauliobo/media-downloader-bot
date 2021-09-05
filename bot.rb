require 'bundler/setup'
require 'active_support/all'
require 'dotenv'
require 'telegram/bot'
Dotenv.load! '.env'

require 'tmpdir'
require 'shellwords'
require 'open3'
require 'rack/mime'
require 'mechanize'

require_relative 'exts/sym_mash'
require_relative 'bot/helpers'
require_relative 'bot/zipper'
require_relative 'bot/worker'

class Bot

  attr_reader :bot
  delegate :api, to: :bot

  include Helpers

  def initialize token
    @token = token
  end

  def start
    Telegram::Bot::Client.run @token, logger: Logger.new(STDOUT) do |bot|
      @bot = bot

      puts 'bot: started, listening'
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
Use `audio` keyword after link to extract audio
Use `nocaption` to remove title and URL

Contribute at https://github.com/brauliobo/media-downloader-bot

Examples:
https://youtu.be/FtGEzUKcAnE audio
https://youtu.be/n8TOOEXsrLw audio nocaption
EOS

  def send_help msg
    send_message msg, START_MSG
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
