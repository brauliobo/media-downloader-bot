require 'concurrent-ruby'
require 'securerandom'

# Template for long jobs run on a thread pool whose progress is polled: subclasses implement `normalize(params)` (the
# job's own fields) and `execute(job, &progress)` (returns the final state, with `errors`), and may override `cancel(job)`.
class BackgroundJobs
  class_attribute :pool_size, default: 1

  def initialize
    @jobs  = {}
    @mutex = Mutex.new
    @pool  = Concurrent::FixedThreadPool.new(pool_size)
  end

  def start(params)
    job = { id: SecureRandom.hex(4), state: 'queued', created_at: Time.now.iso8601, **normalize(params.to_h.deep_symbolize_keys) }
    @mutex.synchronize { @jobs[job[:id]] = job }
    @pool.post { run(job) }
    snapshot(job)
  end

  def fetch(id) = @mutex.synchronize { snapshot(@jobs[id.to_s]) }

  def list = @mutex.synchronize { @jobs.values.map { |job| snapshot(job) } }

  def stop(id)
    job = @mutex.synchronize { @jobs[id.to_s] }
    cancel(job) if job
    fetch(id)
  end

  private

  def cancel(job); end

  def flag(value) = value.to_s.in?(%w[1 true])

  def run(job)
    update(job, state: 'running')
    result = execute(job) { |state| update(job, **state) }
    update(job, **result, state: result[:errors].empty? ? 'completed' : 'failed')
  rescue StandardError, NotImplementedError => e
    update(job, state: 'failed', errors: [{ error: "#{e.class}: #{e.message}" }])
  end

  def update(job, **values) = @mutex.synchronize { job.merge!(values) }

  def snapshot(job) = job&.deep_dup
end
