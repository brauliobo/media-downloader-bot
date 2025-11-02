module Bot
  class UserQueue
    class_attribute :queue_size
    self.queue_size = 1

    def initialize
      @queues = Hash.new { |h, k| h[k] = [] }
      @running = Hash.new { |h, k| h[k] = 0 }
      @mutex = Mutex.new
    end

    def wait_for_slot(user_id, msg, &status_update)
      @mutex.synchronize do
        return mark_running(user_id) if @running[user_id] < queue_size

        queue_line = status_update.call(queue_msg)
        @queues[user_id] << { msg: msg, queue_line: queue_line }
        wait_loop(user_id, queue_line)
      end
    end

    def release_slot(user_id, &block)
      @mutex.synchronize do
        return if @running[user_id] <= 0
        @running[user_id] -= 1
        return unless (next_job = @queues[user_id].shift)
        Thread.new { block.call(next_job[:msg]) }
      end
    end

    private

    def queue_msg
      "Queued - waiting for slot to finish..."
    end

    def mark_running(user_id)
      @running[user_id] += 1
    end

    def wait_loop(user_id, queue_line)
      loop do
        @mutex.unlock
        queue_line&.update(queue_msg)
        sleep 1
        @mutex.lock
        break if @running[user_id] < queue_size
      end
      mark_running(user_id)
    end
  end
end

