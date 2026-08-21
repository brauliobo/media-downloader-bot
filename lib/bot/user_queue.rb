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

    # Parent-side dispatch wrapper: posts a "Queued" status via bot when the user
    # is at the limit, blocks until a slot frees, then yields. The worker replaces
    # that status with its active progress message.
    # Must run in the bot's main process so all messages share queue state.
    def with_user_slot(bot, msg)
      return yield if Jobs.stop_command?(msg.text)

      user_id = msg.from.id
      admin   = Bot::MsgHelpers.from_admin?(msg)
      msg.resp = bot.send_message(msg, Bot::MsgHelpers.me(QUEUED_MSG)) if !admin && queued?(user_id)
      with_slot(user_id, admin: admin) do
        yield
      end
    end
  end
end
