class Worker
  # Keeps as many worker instances of a bot's queue running as it has jobs for: the ones in progress plus the ones a worker could take
  # now (`BotJob.takeable`, so a user at the limit waits without asking for a worker), between `min` and `max`. It only starts
  # instances; those above `min` leave by themselves once idle (Worker::Daemon).
  class Scaler
    INTERVAL  = 5
    STEP_MAX  = 4

    def initialize(queue:, min:, max:, systemd: Utils::Systemd.new)
      @queue, @range, @systemd = queue, min..max, systemd
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
      free   = (1..@range.end).reject { |instance| active.include?(instance) }.first(missing(active.size))
      @systemd.start(@unit, free) if free.any?
    end

    private

    def missing(active) = (demand.clamp(@range) - active).clamp(0, STEP_MAX)

    # In progress here: what the bot runs itself (INLINE) is not a worker's.
    def demand = BotJob.of(@queue).leased.exclude(worker: Bot::Jobs::INLINE).count + BotJob.takeable(@queue).count
  end
end
