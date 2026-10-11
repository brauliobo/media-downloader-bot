module Replay
  # bin/replay: replays the messages forwarded into a chat against the live bot's manager (DRb); the runner works here.
  class CLI < CliBase
    USAGE = "usage: bin/replay chat=<id|title> [parallel=#{Jobs::PARALLEL}] [plan=1] [recover=1]\n".freeze

    self.progress_fields = %i[recovered deleted replayed skipped running errors total]

    def initialize(argv, log: Log.new, forwarded: Forwarding::Log.new, **)
      super(argv, **)
      @log       = log
      @forwarded = forwarded
    end

    # Returns the final state: errors is empty when every message was replayed.
    def run
      chat_id = @resolver.chat_ref(@opts[:chat] || abort(USAGE))[:chat_id]
      recovered = flag(:recover) ? Recovery.new(@manager, log: @log, forwarded: @forwarded).recover(chat_id, plan: flag(:plan)) : {}
      Runner.new(@manager, log: @log, parallel: Integer(@opts[:parallel] || Jobs::PARALLEL))
            .run(messages: @forwarded.copies_in(chat_id), plan: flag(:plan)) { |state| progress(recovered.merge(state)) }
    end
  end
end
