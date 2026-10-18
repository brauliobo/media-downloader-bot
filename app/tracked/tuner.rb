module Tracked
  # Moves the parallelism of the running jobs that ask for it (`tune` in their params) to what the backend they feed takes.
  # `backlog` says how many requests wait for a free slot: none, while a job has all its items running and more waiting, means
  # there is room for one more; a few waiting means too many. Only a streak of the same reading moves it, one step at a time,
  # so a spike changes nothing.
  class Tuner
    INTERVAL = 20

    def initialize(engine, backlog:, min: 1, max: nil, streak: 3, waiting: 2)
      @engine, @backlog, @range, @streak, @waiting = engine, backlog, min..max, streak, waiting
      @votes = []
    end

    def run(interval: INTERVAL)
      loop do
        step
      rescue StandardError => e
        warn "tuner: #{e.class}: #{e.message}"
      ensure
        sleep interval
      end
    end

    def step
      jobs = Job.where(state: 'running').all.select { |job| job.options[:tune] }
      return @votes.clear if jobs.empty?

      @votes = (@votes << vote(@backlog.call)).last(@streak)
      return unless @votes.size == @streak && @votes.uniq.one?

      jobs.each { |job| move(job, @votes.first) }
      @votes.clear
    end

    private

    def vote(waiting) = waiting.zero? ? 1 : (waiting >= @waiting ? -1 : 0)

    def move(job, step)
      return if step.zero? || (step.positive? && !starved?(job))

      parallel = (job.parallel + step).clamp(@range)
      @engine.update(job.id, parallel: parallel) unless parallel == job.parallel
    end

    # Every slot of the job is in use, items are waiting for one and no worker is short of a book: only then is more of it of use.
    # With no `max` the workers are the limit: while a book waits for one, the slots already taken are more than they can use.
    def starved?(job) = JobItem.where(job_id: job.id, status: 'running').count >= job.parallel && JobItem.where(job_id: job.id, status: 'pending').any? && BotJob.where(state: 'queued').empty?
  end
end
