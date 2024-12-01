require_relative 'tl_bot/helpers'

class TlBot

  include Helpers
  self.bot_name = 'media_downloader_bot'
  self.error_delete_time = 3.hours

  class_attribute :bot
  delegate_missing_to :bot

  def self.connect
    Telegram::Bot::Client.run ENV['TL_BOT_TOKEN'], logger: Logger.new(STDOUT) do |bot|
      puts 'bot: started, listening'
      new bot
    end
  end

  def initialize bot
    self.bot = bot
  end

end
