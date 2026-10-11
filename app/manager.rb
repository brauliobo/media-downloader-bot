require 'ostruct'

class Manager

  START_MSG = <<-EOS
Download and convert videos/audios from Youtube, Facebook, Instagram, etc.
Options:
- Use `/stop` to cancel all your active jobs in this chat
- Use `audio` keyword after link to extract audio
- Use `caption` to put title and uploader
- Use `hashtags`, `#`, or `hts` to generate Instagram-style hashtags from transcription
- Use `clang=pt` to translate only the caption
- Use `number` to add the number for each file in playlists

Report issues at https://github.com/brauliobo/media-downloader-bot/issues/new

Examples:
https://youtu.be/FtGEzUKcAnE
https://youtu.be/n8TOOEXsrLw audio caption
https://www.instagram.com/p/CTAXxxODblP/
https://web.facebook.com/groups/590968084832296/posts/920964005166034 audio
https://soundcloud.com/br-ulio-bhavamitra/sets/didi-gunamrta caption number
EOS

  include Service

  attr_reader :bot
  attr_reader :jobs

  def initialize
    @jobs = Bot::Jobs.new
    @edit_posts_jobs = EditPosts::JobManager.new(self) if ENV['TD_BOT']
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
    @bot = Bot::TDBot.start(on_callback: ->(callback) { cancel_job(callback) }) { |msg| react msg }
  end

  def start_tg_bot
    @bot = Bot::TgBot.start(on_callback: ->(callback) { cancel_job(callback) }) { |msg| react msg }
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
    return send_help msg if msg.text&.starts_with?('/start', '/help')
    return if msg.from.id.in? BLOCKED_USERS

    cmd_text = Utils::InputParser.message_text(msg).presence
    return stop_jobs(msg) if Bot::Jobs.stop_command?(cmd_text)
    return Commands::Cookie.new(bot, msg).process if cmd_text&.starts_with?('/cookies') || (msg.document&.file_name&.downcase == 'cookies.txt')
    return if Bot::MsgHelpers.in_group?(msg) && !Utils::InputParser.line_has_url?(cmd_text) && msg.video.blank? && msg.audio.blank? && msg.document.blank?

    enqueue_message msg
  rescue => e
    bot.report_error msg, e rescue nil
    STDERR.puts e.full_message
    raise
  end

  def enqueue_message(msg)
    return jobs.submit(msg) unless ENV['WITH_WORKER']

    job    = jobs.register(msg)
    forked = bot.fork_workers?
    Bot::JobRunner.new(cancelled: jobs.method(:cancelled?), interrupted: ->(_) {}, finished: jobs.method(:finish)).run(job[:id], fork: forked) do
      Sequel::Model.db.disconnect if forked
      Process.setproctitle 'media-downloader-tgbot worker' if forked
      service = forked && bot_service_uri.present? ? Bot::Worker::Client.new(bot_service_uri) : bot
      Worker.new(msg, service: service, job_id: job[:id]).process
    end
  end

  def stop_jobs(msg)
    count = jobs.cancel_all(user_id: msg.from.id, chat_id: msg.chat.id, admin: admin?(msg.from.id))
    bot.send_message(msg, Bot::MsgHelpers.me(I18n.t('bot.stop.result', count: count)))
  end

  def cancel_job(callback)
    id = Bot::Jobs.cancel_id(callback.data)
    return unless id

    result = jobs.cancel(id, user_id: callback.user_id, chat_id: callback.chat_id, admin: admin?(callback.user_id))
    bot.answer_callback(callback, text: cancel_job_message(result))
  end

  private

  def admin?(user_id) = Bot::MsgHelpers::ADMIN_CHAT_ID && user_id.to_i == Bot::MsgHelpers::ADMIN_CHAT_ID

  def cancel_job_message(result)
    {
      cancelled:         'Cancelling...',
      already_cancelled: 'Cancellation already requested',
      forbidden:         'This job belongs to another user',
      not_found:         'This job is no longer active',
    }.fetch(result)
  end
end
