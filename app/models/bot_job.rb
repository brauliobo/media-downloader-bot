Sequel::Model.db.extension :pg_json

# A message a bot has handed to its workers (see Bot::Jobs). Queued until a worker claims it; the claim is a lease that the worker
# renews while it lives, so a row whose lease ran out belongs to a dead worker and is claimable again. Finished rows are deleted.
class BotJob < Sequel::Model(:bot_jobs)
  LEASE        = Integer(ENV.fetch('WORKER_LEASE', 60))
  MAX_ATTEMPTS = 5

  plugin :timestamps, update_on_create: true

  dataset_module do
    def of(queue) = where(queue: queue)

    def leased = where(state: 'running').where(Sequel.|({ lease_until: nil }, Sequel[:lease_until] > Time.now))

    def claimable = where(Sequel.|({ state: 'queued' }, { state: 'running', lease_until: ...Time.now }))

    # Owners that already run as many jobs as `limit`, except the admin.
    def saturated(queue, limit, admin) = of(queue).leased.exclude(owner_id: admin).exclude(owner_id: nil).group(:owner_id).having { count.function.* >= limit }.select(:owner_id)

    # People's jobs first, then the ownerless ones (tracked jobs feeding the bot): a person never waits behind a batch.
    def people_first = order(Sequel.case({ { owner_id: nil } => 1 }, 0), :created_at, :id)

    # Takes the oldest job nobody holds, atomically so that concurrent workers never share one, and leases it to `worker`.
    # Jobs that outlived their attempts (they keep killing their workers) are dropped; a user at their limit waits.
    def claim(queue, worker, limit: Bot::UserQueue.limit, admin: Bot::MsgHelpers::ADMIN_CHAT_ID)
      of(queue).claimable.where { attempts >= MAX_ATTEMPTS }.delete
      db.transaction do
        id  = of(queue).claimable.exclude(owner_id: saturated(queue, limit, admin)).people_first.for_update.skip_locked.get(:id)
        row = where(id: id).returning.update(state: 'running', worker: worker, lease_until: Time.now + LEASE, attempts: Sequel[:attempts] + 1, updated_at: Time.now).first if id
        model.call(row) if row
      end
    end

    # The status message the job keeps up to date, kept in its message (`resp`) so that a worker resuming the job edits it instead of posting another.
    def remember_status(id, message_id) = where(id: id.to_s).update(message: Sequel.lit('message || ?::jsonb', { resp: { message_id: message_id } }.to_json))

    def renew(worker) = where(worker: worker, state: 'running').update(lease_until: Time.now + LEASE)

    # Gives a job back, unharmed by the attempt: its worker stopped on purpose.
    def release = update(state: 'queued', worker: nil, lease_until: nil, attempts: Sequel[:attempts] - 1)
  end

  def envelope = { id: id, owner_id: owner_id, chat_id: chat_id, message: message.to_h.deep_symbolize_keys }
end
