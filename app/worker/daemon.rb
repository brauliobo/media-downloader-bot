require 'socket'
require 'set'

class Worker
  # A worker process of a bot, pointed at the bot's service by address (BOT_HTTP or BOT_DRB): it takes the jobs of the bot's queue
  # one at a time and renews the lease of the one it holds, so the bot restarting changes nothing for it.
  #
  # USR2, TERM and INT make it stop taking jobs and end once the job in flight does; a process manager that restarts it then
  # brings the replacement up. USR2 waits as long as the job takes, TERM and INT only up to DRAIN_TIMEOUT. The same signal twice, or
  # the timeout, hands the job back to the queue and stops at once: whoever takes it next resumes it from its work dir.
  class Daemon
    POLL          = 1
    DRAIN_TIMEOUT = Integer(ENV.fetch('WORKER_DRAIN_TIMEOUT', 540))
    SIGNALS       = { USR2: nil, TERM: DRAIN_TIMEOUT, INT: DRAIN_TIMEOUT }.freeze

    attr_reader :id

    def initialize(service_uri = ENV['BOT_HTTP'] || ENV['BOT_DRB'], service: Bot::Worker::Client.new(service_uri))
      @service = service
      @id      ="#{Socket.gethostname}-#{Process.pid}-#{SecureRandom.hex(3)}"
      @signals = Set.new
    end

    def run
      SIGNALS.each { |signal, timeout| trap(signal) { stop(signal, timeout) } }
      @jobs = Bot::Jobs.new(queue: @service.queue_name)
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
      until @draining
        job = @jobs.dequeue(worker: id)
        job ? process(job) : sleep(POLL)
      end
    end

    def process(job)
      @restarted = @interrupted = false
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

    def interruption(_job_id)
      return unless hard? && !@interrupted

      @interrupted = true
      :restart
    end

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
