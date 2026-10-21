class Worker
  # Keeps as many worker instances of a bot's queue running as it has jobs for: the ones in progress plus the ones a worker could take
  # now (`BotJob.takeable`, so a user at the limit waits without asking for a worker), up to `max`; none when nothing waits. It only
  # starts instances; each one leaves by itself after its book (Worker::Daemon).
  class Scaler
    INTERVAL  = 5
    STEP_MAX  = 4

    def initialize(queue:, max:, systemd: Utils::Systemd.new)
      @queue, @max, @systemd = queue, max, systemd
      @unit = "media-downloader-#{queue}-worker"
    end

    def run(interval: INTERVAL)
      loop do
        step
      rescue StandardError => e
        warn "worker scaler: #{e.class}: #{e.message}"
      ensure
        sleep interval
      end
    end

    def step
      active = @systemd.active(@unit)
      free   = (1..@max).reject { |instance| active.include?(instance) }.first(missing(active.size))
      @systemd.start(@unit, free) if free.any?
    end

    private

    def missing(active) = (demand.clamp(0, @max) - active).clamp(0, STEP_MAX)

    # In progress here: what the bot runs itself (INLINE) is not a worker's.
    def demand = BotJob.of(@queue).leased.exclude(worker: Bot::Jobs::INLINE).count + BotJob.takeable(@queue).count
  end
end
