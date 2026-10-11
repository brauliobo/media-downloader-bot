module Replay
  # Feeds stored messages to the bot as if just received, keeping at most `parallel` of them in flight.
  class Runner
    def initialize(manager, log: Log.new, parallel: 6)
      @manager  = manager
      @log      = log
      @parallel = parallel
      @mutex    = Mutex.new
      @stopped  = false
    end

    # messages: [{chat_id:, id:}] oldest first; plan: only count what would be replayed.
    def run(messages:, plan: false, &progress)
      @progress = progress
      pending   = messages.reject { |message| log.replayed?(message[:chat_id], message[:id]) }
      @state    = { total: messages.size, replayed: 0, skipped: messages.size - pending.size, running: 0, errors: [] }
      notify
      replay_all(pending) unless plan
      @state
    end

    def stop! = @stopped = true

    private

    attr_reader :manager, :log

    def replay_all(pending)
      queue = Queue.new
      pending.each { |message| queue << message }
      queue.close
      Array.new([@parallel, pending.size].min) { Thread.new { work(queue) } }.each(&:join)
    end

    def work(queue)
      until @stopped
        message = queue.pop or break
        replay(message)
      end
    end

    # Logged on submission: a failure or restart never converts the same book twice.
    def replay(message)
      update { @state[:running] += 1 }
      log.record(message[:chat_id], message[:id])
      manager.replay_message(chat_id: message[:chat_id], message_id: message[:id])
      update { @state[:replayed] += 1 }
    rescue => e
      update { @state[:errors] << { id: message[:id], error: "#{e.class}: #{e.message}" } }
    ensure
      update { @state[:running] -= 1 }
    end

    def update
      @mutex.synchronize do
        yield
        notify
      end
    end

    def notify = @progress&.call(@state)
  end
end
