require 'ostruct'

class Manager

  START_MSG = <<-EOS
Download and convert videos/audios from Youtube, Facebook, Instagram, etc.
Options:
- Use `/stop` to cancel all your active jobs in this chat, or reply `/stop` to a status message to cancel only that job
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
    @jobs = Bot::Jobs.new(queue: ENV['TD_BOT'] ? 'tdbot' : 'tgbot')
    @edit_posts_jobs = EditPosts::JobManager.new(self) if ENV['TD_BOT']
    @forwarding = Forwarding::Jobs.new(-> { bot })
    @tracked = Tracked::Engine.new({ 'replay' => Replay::Handler.new(self) })
    @relay = Relay::Dispatcher.new(-> { bot })
  end

  def self.http
    Utils::HTTP.client
  end

  def mock_start
    @bot = Bot::Mock.new
  end

  def start
    @jobs.drop_inline!
    start_td_bot if ENV['TD_BOT']
    start_tg_bot if ENV['TG_BOT']
    @relay.recover!
    @tracked.recover! if ENV['TD_BOT'] # replay needs tdlib; the Telegram bot API can't read chats
    start_tuner if ENV['TD_BOT']
    start_bot_service
    start_frontend
    sleep 1.year while true
  end

  # The jobs that ask for it (`tune`) take as many items at once as the TTS pool of the router has room for, up to TUNE_MAX_PARALLEL.
  def start_tuner
    router = Utils::Oxiroute.new
    tuner  = Tracked::Tuner.new(@tracked, backlog: -> { router.queue_depth(ENV.fetch('TUNE_POOL', 'omnivoice_nodes')) }, max: ENV.fetch('TUNE_MAX_PARALLEL', 9).to_i)
    Thread.new { tuner.run }
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

  # `queued` messages come out of a group's queue, so they are processed now instead of joining it again.
  def react(msg, queued: false)
    @relay.dispatch(msg)
    msg.bot = bot
    msg.bot_type = bot.class.name
    return if msg.is_outgoing
    return if msg.text.blank? && msg.video.blank? && msg.audio.blank? && msg.document.blank?
    return send_help msg if msg.text&.starts_with?('/start', '/help')
    return if msg.from.id.in? BLOCKED_USERS
    return if Bot::MsgHelpers.in_group?(msg) && !ChatSetting.respond?(msg.chat.id)

    cmd_text = Utils::InputParser.message_text(msg).presence
    return stop_jobs(msg) if Bot::Jobs.stop_command?(cmd_text)
    return Commands::Cookie.new(bot, msg).process if cmd_text&.starts_with?('/cookies') || (msg.document&.file_name&.downcase == 'cookies.txt')
    return if Bot::MsgHelpers.in_group?(msg) && !Utils::InputParser.line_has_url?(cmd_text) && msg.video.blank? && msg.audio.blank? && msg.document.blank?

    return if !queued && ENV['TD_BOT'] && queue_message(msg)

    enqueue_message msg, queued: queued
  rescue => e
    bot.report_error msg, e rescue nil
    STDERR.puts e.full_message
    raise
  end

  def enqueue_message(msg, queued: false)
    return jobs.submit(msg, owner: (msg.from.id unless queued)) unless ENV['WITH_WORKER']

    job    = jobs.register(msg)
    forked = bot.fork_workers?
    runner = Bot::JobRunner.new(cancelled: jobs.method(:cancelled?), interrupted: ->(_) {}, finished: jobs.method(:finish))
    runner.run(job[:id], fork: forked) do
      Sequel::Model.db.disconnect if forked
      Process.setproctitle 'media-downloader-tgbot worker' if forked
      service = forked && bot_service_uri.present? ? Bot::Worker::Client.new(bot_service_uri) : bot
      Worker.new(msg, service: service, job_id: job[:id]).process
    end
    job
  end

  def stop_jobs(msg)
    id = bot.reply_job_id(msg)
    return stop_replied_job(msg, id) if id

    count = jobs.cancel_all(user_id: msg.from.id, chat_id: msg.chat.id, admin: admin?(msg.from.id))
    bot.send_message(msg, Bot::MsgHelpers.me(I18n.t('bot.stop.result', count: count)))
  end

  def stop_replied_job(msg, id)
    result = jobs.cancel(id, user_id: msg.from.id, chat_id: msg.chat.id, admin: admin?(msg.from.id))
    bot.send_message(msg, Bot::MsgHelpers.me(cancel_job_message(result)))
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
