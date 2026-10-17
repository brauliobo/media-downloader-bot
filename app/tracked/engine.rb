module Tracked
  # Runs jobs on top of the database: up to `job.parallel` threads claim the pending items of each running job, and every
  # outcome stays in the rows. Stopping, changing the parallelism and resuming after a restart only touch rows. A job of a
  # standing kind keeps running when it has nothing pending, waiting for items added with `add`.
  class Engine
    TICK         = 1
    MAX_PARALLEL = 10
    ERRORS       = [StandardError, NotImplementedError].freeze

    def initialize(handlers, tick: TICK)
      @handlers = handlers
      @tick     = tick
      @pool     = Concurrent::CachedThreadPool.new
    end

    def start(kind:, parallel: nil, params: {})
      handler = handler_for(kind)
      enqueue(Job.create(kind: kind, parallel: clamp(parallel || handler.parallel), params: handler.normalize(params))).to_api
    end

    # A queued job stops at once, a running one after the items in flight.
    def stop(id)
      job = Job.with_pk!(id)
      job.update(state: job.state == 'queued' ? 'stopped' : 'stopping') if job.state.in?(%w[queued running])
      job.to_api
    end

    def resume(id)
      job = Job.with_pk!(id)
      (job.state.in?(%w[stopped completed failed]) ? enqueue(job) : job).to_api
    end

    # Takes effect on the next tick of a running job.
    def update(id, parallel: nil, params: nil)
      job = Job.with_pk!(id)
      job.update({ parallel: (clamp(parallel) if parallel), params: (handler_for(job.kind).normalize(job.options.merge(params.to_h.symbolize_keys)) if params) }.compact).to_api
    end

    # Puts failed items back in line and wakes their jobs up; returns how many. With `discard` the done ones go too, after
    # deleting from their chats whatever was sent for them: they are reprocessed from scratch.
    def retry_items(ids, discard: false)
      items = JobItem.where(id: ids, status: discard ? %w[done failed] : 'failed')
      jobs  = items.select_map(:job_id).uniq
      items.all.each { |item| item.messages_dataset.live.each { |message| handler_for(item.kind).delete_message(message) } } if discard
      items.update({ status: 'pending', error: nil, finished_at: nil, updated_at: Time.now }.merge(discard ? { attempts: 0 } : {})).tap { jobs.each { |id| resume(id) } }
    end

    # Puts a new item in a job's line (nothing happens if the item is already known) and returns it.
    def add(job_id, key)
      job = Job.with_pk!(job_id)
      handler = handler_for(job.kind)
      fresh   = JobItem.dataset.insert_conflict(target: %i[kind key]).insert(job_id: job.id, kind: job.kind, key: key)
      JobItem.first(kind: job.kind, key: key).tap do |item|
        describe_item(handler, item)
        @pool.post { announce(handler, item) } if fresh
      end
    end

    # Changes what a finished item recorded (e.g. its hashtags); `apply` then publishes it.
    def edit(id, result)
      item = JobItem.with_pk!(id)
      item.update(result: item.outcome.merge(result.to_h.symbolize_keys)).to_api
    end

    def apply(id)
      item = JobItem.with_pk!(id)
      handler_for(item.kind).apply(item)
      item.refresh.to_api
    end

    # Deletes a tracked message from its chat.
    def delete_message(id)
      message = JobMessage.with_pk!(id)
      handler_for(message.job_item.kind).delete_message(message)
      message.refresh.to_api
    end

    # After a restart: whatever was in flight goes back in line (a handler checks what the dead run already did) and
    # unfinished jobs continue.
    def recover!
      JobItem.running.update(status: 'pending', updated_at: Time.now)
      Job.where(state: 'stopping').update(state: 'stopped')
      Job.where(state: %w[queued running]).order(:id).each { |job| enqueue(job) }
    end

    private

    def handler_for(kind) = @handlers.fetch(kind.to_s) { raise ArgumentError, "unknown job kind #{kind.inspect}" }

    def clamp(parallel) = Integer(parallel).clamp(1, MAX_PARALLEL)

    def enqueue(job)
      job.update(state: 'queued', error: nil, finished_at: nil)
      @pool.post { run(job.id) }
      job
    end

    def run(id)
      job = Job.with_pk!(id)
      return unless job.state == 'queued'

      job.update(state: 'running', started_at: Time.now)
      handler = handler_for(job.kind)
      seed(job, handler)
      describe(job, handler)
      work(job, handler)
      finish(job)
    rescue *ERRORS => e
      warn "job #{id}: #{e.class}: #{e.message}"
      job&.update(state: 'failed', error: "#{e.class}: #{e.message}", finished_at: Time.now)
    end

    # Every item of the job's scope joins it, so its counts tell the whole story; failed ones go back in line if asked to.
    # A row may bring the messages already sent for it.
    def seed(job, handler)
      rows = handler.seed(job)
      rows.each_slice(500) { |slice| JobItem.dataset.insert_conflict(target: %i[kind key]).multi_insert(slice.map { |row| { job_id: job.id, kind: job.kind, **row.except(:messages) } }) }
      rows.select { |row| row[:messages].present? }.each { |row| JobItem.first(kind: job.kind, key: row[:key]).record_messages(row[:messages]) }
      items = JobItem.where(kind: job.kind, key: rows.map { |row| row[:key] })
      items.failed.update(status: 'pending', error: nil, finished_at: nil) if job.options[:retry_failed]
      items.update(job_id: job.id)
    end

    # Items that don't show yet what they are about get it now; one that can't be described says why instead.
    def describe(job, handler)
      JobItem.where(job_id: job.id).exclude(Sequel.pg_jsonb_op(:result).has_key?('input')).each { |item| describe_item(handler, item) }
    end

    def describe_item(handler, item)
      input = begin
        handler.describe(item)
      rescue *ERRORS => e
        { error: "#{e.class}: #{e.message}" }
      end
      item.update(result: item.outcome.merge(input: input)) if input
    end

    def work(job, handler)
      threads = []
      while job.refresh.state == 'running'
        threads.select!(&:alive?)
        fill(job, handler, threads)
        break if threads.empty? && !handler.standing?(job)

        sleep @tick
      end
      threads.each(&:join)
    end

    def fill(job, handler, threads)
      (job.parallel - threads.size).times do
        item = JobItem.claim(job.id) or return
        threads << Thread.new { perform(handler, job, item) }
      end
    end

    def perform(handler, job, item)
      settle(handler, item, handler.perform(job, item))
    rescue *ERRORS => e
      item.update(status: 'failed', error: "#{e.class}: #{e.message}", finished_at: Time.now)
    end

    def settle(handler, item, result)
      error = handler.error_of(result)
      item.record_messages(result.fetch(:messages, []))
      item.update(status: error ? 'failed' : 'done', error: error, result: item.outcome.merge(result.except(:messages)), finished_at: Time.now)
    end

    # Off the caller's thread (it may read the item's file); an item a thread of the job took meanwhile is left to it.
    def announce(handler, item)
      result = handler.queued(item)
      settle(handler, item, result) if result && item.refresh.status == 'pending'
    rescue *ERRORS => e
      warn "item #{item.id}: #{e.class}: #{e.message}"
    end

    def finish(job)
      stopped = job.refresh.state == 'stopping'
      failed  = JobItem.failed.where(job_id: job.id).any?
      job.update(state: stopped ? 'stopped' : (failed ? 'failed' : 'completed'), finished_at: Time.now)
    end
  end
end
