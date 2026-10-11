class Manager
  # What the manager answers to workers and other processes over DRb and HTTP: keyword arguments throughout.
  module Service
    delegate :max_caption, :find_chats, :resolve_chat_identifier, :chat_messages, :chat_message, :ensure_forum_topic, to: :bot
    delegate :dequeue, to: :jobs
    delegate :size, to: :jobs, prefix: :queue

    def job_cancelled(id:) = jobs.cancelled?(id)
    def finish_job(id:) = jobs.finish(id)

    def start_edit_posts_job(args) = @edit_posts_jobs.start(args)
    def edit_posts_job(id) = @edit_posts_jobs.fetch(id)
    def edit_posts_jobs = @edit_posts_jobs.list
    def edit_posts_job_log(id, lines: 100) = @edit_posts_jobs.log(id, lines: lines)

    def bot_service_uri = ENV['BOT_DRB'].presence || ENV['BOT_HTTP'].presence

    def start_bot_service
      Bot::Worker::HTTPService.start(self, http_port, host: http_host) if ENV['BOT_HTTP']
      Bot::Worker::DRbService.start(self, ENV['BOT_DRB']) if ENV['BOT_DRB']
    end

    def edit_generated_message(...) = remote { drb_result bot.edit_generated_message(...) }
    def upload_generated_media(...) = remote { drb_result bot.upload_generated_media(...) }

    def send_message(msg:, text:, **params) = drb_result bot.send_message(msg, text, **params)
    def edit_message(msg:, id:, **params) = drb_result bot.edit_message(msg, id, **params)

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
