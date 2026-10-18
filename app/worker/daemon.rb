require 'socket'
require 'set'

class Worker
  # A worker process of a bot, pointed at the bot's service by address (BOT_HTTP or BOT_DRB): it takes the jobs of the bot's queue
  # one at a time and renews the lease of the one it holds, so the bot restarting changes nothing for it.
  #
  # USR2, TERM and INT make it stop taking jobs and end once the job in flight does; a process manager that restarts it then
  # brings the replacement up. USR2 waits as long as the job takes, TERM and INT only up to DRAIN_TIMEOUT. The same signal twice, or
  # the timeout, stops the job: it is asked to (Bot::JobRestarted) and leaves at its next checkpoint, in seconds, with its files whole,
  # and goes back to the queue; whoever takes it next resumes it from its work dir. Only a job that reaches no checkpoint in
  # Bot::JobRunner::STOP_GRACE has the stop thrown into it.
  class Daemon
    POLL          = 1
    DRAIN_TIMEOUT = Integer(ENV.fetch('WORKER_DRAIN_TIMEOUT', 540))
    SIGNALS       = { USR2: nil, TERM: DRAIN_TIMEOUT, INT: DRAIN_TIMEOUT }.freeze
    # What a worker above WORKER_MIN leaves with after WORKER_IDLE_EXIT seconds without a job; the unit does not restart that status.
    RETIRED_STATUS = 75

    attr_reader :id

    # The instances above WORKER_MIN are the ones the scaler starts (Worker::Scaler): they leave when idle, the others stay.
    def self.retire_after
      ENV.fetch('WORKER_IDLE_EXIT', 120).to_f if ENV['WORKER_MIN'] && ENV['SYSTEMD_INSTANCE'].to_i > ENV['WORKER_MIN'].to_i
    end

    def initialize(service_uri = ENV['BOT_HTTP'] || ENV['BOT_DRB'], service: Bot::Worker::Client.new(service_uri), retire_after: self.class.retire_after)
      @service      = service
      @retire_after = retire_after
      @id           = "#{Socket.gethostname}-#{Process.pid}-#{SecureRandom.hex(3)}"
      @signals      = Set.new
    end

    def retired? = @retired.present?

    def run
      Thread.abort_on_exception = false # a thread of a stopped job (a reader of its subprocess) ending must not take the worker down
      SIGNALS.each { |signal, timeout| trap(signal) { stop(signal, timeout) } }
      @jobs = Bot::Jobs.new(queue: @service.queue_name)
      Zipper.size_mb_limit = @service.size_mb_limit # what it makes is uploaded by its bot, within its limit
      Worker.prune_workdirs
      lease = keep_lease
      puts "worker #{id} takes the jobs of #{@jobs.queue}"
      take_jobs
      puts "worker #{id} stopped"
    ensure
      lease&.kill
    end

    private

    def take_jobs
      idle_since = monotonic
      until @draining
        if (job = @jobs.dequeue(worker: id))
          process(job)
          idle_since = monotonic
        else
          retire if @retire_after && monotonic - idle_since > @retire_after
          sleep POLL
        end
      end
    end

    def retire = @retired = @draining = true

    def process(job)
      @restarted = false
      runner = Bot::JobRunner.new(cancelled: @jobs.method(:cancelled?), interrupted: method(:interruption), finished: method(:finish))
      runner.run(job[:id]) { work(job) }
    end

    def work(job)
      Worker.new(SymMash.new(job[:message]), service: @service, job_id: job[:id]).process
    rescue Bot::JobRestarted
      @restarted = true
      raise
    end

    # A job that was stopped to restart goes back to the queue, any other one is over.
    def finish(job_id) = @restarted ? @jobs.release(job_id) : @jobs.finish(job_id)

    # Asked at every poll of the runner, which asks the job once and throws the stop into it if it takes too long.
    def interruption(_job_id) = (:restart if hard?)

    # Signal handlers only set flags.
    def stop(signal, timeout)
      @hard      ||= !@signals.add?(signal)
      @draining    = true
      @deadline    = [@deadline, (monotonic + timeout if timeout)].compact.min
    end

    def hard? = @hard || (@deadline && monotonic > @deadline)

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def keep_lease = Thread.new { loop { sleep BotJob::LEASE / 3; renew } }

    # A failure is reported and tried again: giving up would let the lease run out under a live job.
    def renew
      @jobs.heartbeat(id)
    rescue => e
      warn "worker #{id}: lease renewal failed: #{e.class}: #{e.message}"
    end
  end
end
