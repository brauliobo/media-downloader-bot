module Replay
  # Replays, as freshly received, the messages forwarded into a chat; the runner of each job is kept apart so snapshots stay JSON-safe.
  class Jobs < BackgroundJobs
    PARALLEL = 6

    def initialize(manager, log: Log.new, forwarded: Forwarding::Log.new)
      super()
      @manager   = manager
      @log       = log
      @forwarded = forwarded
      @runners   = Concurrent::Map.new
    end

    private

    def execute(job, &progress)
      progress.call(Recovery.new(@manager, log: @log, forwarded: @forwarded).recover(job[:chat_id], plan: job[:plan])) if job[:recover]
      runner = @runners[job[:id]] = Runner.new(@manager, log: @log, parallel: job[:parallel])
      runner.run(messages: @forwarded.copies_in(job[:chat_id]), plan: job[:plan], &progress)
    end

    def cancel(job) = @runners[job[:id]]&.stop!

    def normalize(params)
      { chat_id: Integer(params.fetch(:chat_id)), parallel: Integer(params[:parallel] || PARALLEL).clamp(1, 10), plan: flag(params[:plan]), recover: flag(params[:recover]) }
    end
  end
end
