module Bot
  class UserQueue
    QUEUED_MSG = 'Queued'.freeze

    class_attribute :limit
    self.limit = 1

    def self.instance
      @instance ||= new
    end

    def initialize
      @running = Hash.new(0)
      @mutex   = Mutex.new
      @cond    = ConditionVariable.new
    end

    def queued?(user_id)
      @mutex.synchronize { @running[user_id] >= limit }
    end

    def acquire(user_id)
      @mutex.synchronize do
        @cond.wait(@mutex) while @running[user_id] >= limit
        @running[user_id] += 1
      end
    end

    def release(user_id)
      @mutex.synchronize do
        @running[user_id] -= 1
        @running.delete(user_id) if @running[user_id] <= 0
        @cond.broadcast
      end
    end

    def with_slot(user_id, admin: false)
      return yield if admin
      acquire(user_id)
      begin
        yield
      ensure
        release(user_id)
      end
    end
  end
end
