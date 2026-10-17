require 'securerandom'

module Bot
  # What a bot's workers have to do, kept in the database (BotJob) so that neither the bot nor a worker restarting loses it.
  # `submit` queues a message for the workers of the bot's `queue`; `register` tracks one the bot runs itself. A message is
  # queued once while it is active: submitting it again returns the job it already has.
  class Jobs
    CANCEL_PREFIX = 'job:cancel:'.freeze
    STOP_COMMAND  = %r{\A/stop(?:@\w+)?(?:\s|\z)}i.freeze
    INLINE        = 'inline'.freeze

    attr_reader :queue

    def initialize(queue: 'default') = @queue = queue

    # `owner` is who the job counts against (one running job per user); none for what a tracked job feeds the bot, that has its own limit.
    def submit(msg, owner: msg.from.id) = insert(msg, owner: owner, message: msg.to_h.except(:bot, :resp))

    def register(msg) = insert(msg, state: 'running', worker: INLINE)

    # A worker takes the next job and holds it until it finishes or releases it, renewing the lease through `heartbeat`.
    def dequeue(worker:) = BotJob.claim(queue, worker)&.envelope

    def heartbeat(worker) = BotJob.renew(worker)

    def release(id) = mine.where(id: id.to_s).release.then { true }

    # Whatever the bot ran itself died with it.
    def drop_inline! = mine.where(worker: INLINE).delete

    def size = mine.where(state: 'queued').count

    def cancel(id, user_id:, chat_id:, admin: false)
      job = mine.first(id: id.to_s) or return :not_found
      return :forbidden unless admin || (job.owner_id == user_id.to_i && job.chat_id == chat_id.to_i)
      return :already_cancelled if job.cancelled

      job.update(cancelled: true)
      :cancelled
    end

    def cancel_all(user_id:, chat_id:, admin: false)
      jobs = mine.where(cancelled: false)
      jobs = jobs.where(owner_id: user_id.to_i, chat_id: chat_id.to_i) unless admin
      jobs.update(cancelled: true)
    end

    def active?(id) = mine.where(id: id.to_s).any?

    # The job a message is active in, if any.
    def job_for(key) = mine.first(key: key)&.envelope

    def cancelled?(id) = mine.where(id: id.to_s, cancelled: true).any?

    def finish(id) = mine.where(id: id.to_s).delete.then { true }

    def self.cancel_data(id)
      "#{CANCEL_PREFIX}#{id}"
    end

    def self.cancel_id(data)
      value = data.to_s
      value.delete_prefix(CANCEL_PREFIX) if value.start_with?(CANCEL_PREFIX)
    end

    def self.stop_command?(text)
      text.to_s.match?(STOP_COMMAND)
    end

    # What identifies a message for as long as it is active, nil for one that has no id.
    def self.key_of(msg)
      id = msg.message_id || msg.id
      "#{msg.chat.id}:#{id}" if id
    end

    private

    def mine = BotJob.of(queue)

    def insert(msg, owner: msg.from.id, message: {}, **attrs)
      row = { id: SecureRandom.urlsafe_base64(12), queue: queue, key: self.class.key_of(msg), owner_id: owner, chat_id: msg.chat.id,
              message: Sequel.pg_jsonb(message), **attrs }
      BotJob.dataset.insert_conflict(target: %i[queue key]).insert(row)
      (row[:key] ? mine.first(key: row[:key]) : BotJob.with_pk!(row[:id])).envelope
    end
  end
end
