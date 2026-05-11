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

    # Parent-side dispatch wrapper: posts a "Queued" notice via bot when the user
    # is at the limit, blocks until a slot frees, deletes the notice, then yields.
    # Must run in the bot's main process so all messages share queue state.
    def with_user_slot(bot, msg)
      user_id = msg.from.id
      admin   = Bot::MsgHelpers.from_admin?(msg)
      queued_msg = (bot.send_message(msg, Bot::MsgHelpers.me(QUEUED_MSG)) if !admin && queued?(user_id))
      with_slot(user_id, admin: admin) do
        bot.delete_message(msg, queued_msg.message_id) if queued_msg
        yield
      end
    end
  end
end
