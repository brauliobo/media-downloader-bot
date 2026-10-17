class Manager
  # What the manager answers to workers and other processes over DRb and HTTP: keyword arguments throughout.
  module Service
    delegate :max_caption, :find_chats, :resolve_chat_identifier, :chat_message, :ensure_forum_topic, *Bot::Base::CHAT_OPERATIONS, to: :bot
    delegate :size, to: :jobs, prefix: :queue

    # The queue this bot's workers take their jobs from.
    def queue_name = jobs.queue

    # The biggest file this bot uploads (nil for no limit), which the workers encode and stream to fit.
    def size_mb_limit = Zipper.size_mb_limit

    def job_cancelled(id:) = jobs.cancelled?(id)
    def finish_job(id:) = jobs.finish(id)

    # Whether a message is being processed or waits for a worker.
    def message_job_active?(chat_id:, message_id:) = jobs.job_for("#{chat_id}:#{message_id}").present?

    def start_edit_posts_job(args) = @edit_posts_jobs.start(args)
    def edit_posts_job(id) = @edit_posts_jobs.fetch(id)
    def edit_posts_jobs = @edit_posts_jobs.list
    def edit_posts_job_log(id, lines: 100) = @edit_posts_jobs.log(id, lines: lines)

    def start_forwarding(params) = @forwarding.start(params)
    def forwarding_job(id) = @forwarding.fetch(id)
    def forwarding_jobs = @forwarding.list

    # Resumable jobs kept in the database (see Tracked::Engine): tracked_start, tracked_stop, tracked_resume, ...
    delegate :start, :stop, :resume, :update, :retry_items, :edit, :apply, :delete_message, to: :@tracked, prefix: :tracked

    # Turns the queue of a group on or off (its latest replay job follows the chat, or one starts) and sets its slots.
    def group_queue(chat_id:, enabled:, parallel: nil)
      job = Replay::GroupQueue.jobs(chat_id).first or return @tracked.start(kind: 'replay', parallel: parallel, params: { chat_id: chat_id, follow: enabled })

      @tracked.update(job.id, parallel: parallel, params: { follow: enabled })
      @tracked.resume(job.id) if enabled
      job.refresh.to_api
    end

    # Reads the language of the job's books from their posted ymls in the background; the items show it as it is filled in.
    def check_languages(job_id:) = Thread.new { Replay::LangCheck.new(self).call(Job.with_pk!(job_id)) }.then { true }

    # A message posted in a group with a queue joins it; nil when the group has none.
    def queue_message(msg)
      job = Replay::GroupQueue.job_for(msg.chat.id) or return
      @tracked.add(job.id, "#{msg.chat.id}:#{msg.id}")
    end

    # Posts the standard "Queued" reply to a stored message.
    def announce_queued(chat_id:, message_id:) = Bot::UserQueue.announce(bot, bot.incoming_message(chat_id: chat_id, message_id: message_id)).then { true }

    # What a stored message feeds the bot: its type, file name, text, and the url and options of each line.
    def message_input(chat_id:, message_id:) = Replay::Input.of(bot.incoming_message(chat_id: chat_id, message_id: message_id))

    # The SHA-256 of the file a stored message carries; nil for a message without one.
    def message_checksum(chat_id:, message_id:)
      msg  = bot.incoming_message(chat_id: chat_id, message_id: message_id)
      kind = Relay::Filter.kind(msg) or return
      Digest::SHA256.file(bot.download_file(msg[kind])).hexdigest
    end

    # Answers a stored message (in its topic) with plain text.
    def reply_to_message(chat_id:, message_id:, text:) = send_message(msg: bot.incoming_message(chat_id: chat_id, message_id: message_id), text: text, parse_mode: nil)

    # Feeds a stored message to the bot as if just received and blocks until its job ends. A message that already has a job (a
    # worker kept it through a restart of the bot) is waited for, not fed again.
    def replay_message(chat_id:, message_id:)
      job = jobs.job_for("#{chat_id}:#{message_id}") || react(bot.incoming_message(chat_id: chat_id, message_id: message_id), queued: true)
      sleep 0.5 while job && jobs.active?(job[:id])
      true
    end

    def retry_relay(id) = @relay.retry(id)
    def retry_failed_relays = @relay.retry_failed

    def stop_job(id:) = jobs.cancel(id, user_id: 0, chat_id: 0, admin: true)

    def bot_service_uri = ENV['BOT_DRB'].presence || ENV['BOT_HTTP'].presence

    def start_frontend = (WebServer.start(self, ENV.fetch('FRONTEND_PORT').to_i) if ENV['FRONTEND_PORT'])

    def start_bot_service
      Bot::Worker::HTTPService.start(self, http_port, host: http_host) if ENV['BOT_HTTP']
      Bot::Worker::DRbService.start(self, ENV['BOT_DRB']) if ENV['BOT_DRB']
    end

    def edit_generated_message(...) = remote { drb_result bot.edit_generated_message(...) }
    def upload_generated_media(...) = remote { drb_result bot.upload_generated_media(...) }

    def send_message(msg:, text:, **params) = drb_result bot.send_message(msg, text, **params)
    def edit_message(msg:, id:, **params) = drb_result(bot.edit_message(msg, id, **params)).tap { jobs.touch(msg) }

    def send_album(msg:, text:, uploads:, **params)
      remote do
        staged = Array(uploads).map { |upload| SymMash.new(upload) }
        Array(bot.send_album(msg, text, uploads: staged, **params)).map { |result| Bot::MessageResult.dump(result) }
      end
    end

    def delete_message(msg:, id:, **params)
      bot.delete_message(msg, id, **params)
      true
    end

    def report_error(msg:, e:, error_class: nil, context: nil)
      error = StandardError.new(e)
      error.define_singleton_method(:class) { OpenStruct.new(name: error_class) } if error_class
      bot.report_error(msg, error, context: context)
      true
    end

    def download_file(file_id_or_info = nil, **params)
      bot.download_file(params.delete(:file_id_or_info) || file_id_or_info, **params)
    end

    private

    def http_port = URI.parse(ENV['BOT_HTTP']).port || 8080
    def http_host = URI.parse(ENV['BOT_HTTP']).host.presence || ENV['BOT_HTTP_BIND'].presence || '127.0.0.1'

    def drb_result(result) = result.respond_to?(:to_h) ? result.to_h : result

    # What crosses to another process is a message alone: the exception's class and cause may not exist there.
    def remote
      yield
    rescue => e
      raise RuntimeError, drb_error_message(e), cause: nil
    end

    def drb_error_message(error)
      message = "#{error.class}: #{error.message}"
      body    = error.try(:response).try(:body)
      body.present? ? "#{message}: #{body}" : message
    end
  end
end
