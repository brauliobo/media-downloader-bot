module Bot
  class UserQueue
    QUEUED_MSG = 'Queued'.freeze
    BUSY_MSG   = 'The service is busy. Please try again later.'.freeze
    ACTIVE_LIMIT  = [ENV.fetch('BOT_MAX_ACTIVE_JOBS', 8).to_i, 1].max
    PENDING_LIMIT = [ENV.fetch('BOT_MAX_PENDING_JOBS', 50).to_i, ACTIVE_LIMIT].max

    class_attribute :limit
    self.limit = 1

    def self.instance
      @instance ||= new
    end

    def initialize
      @running = Hash.new(0)
      @active  = 0
      @pending = 0
      @mutex   = Mutex.new
      @cond    = ConditionVariable.new
    end

    def reserve_dispatch
      @mutex.synchronize do
        return false if @pending >= PENDING_LIMIT
        @pending += 1
        true
      end
    end

    def release_dispatch
      @mutex.synchronize { @pending -= 1 if @pending.positive? }
    end

    def queued?(user_id)
      @mutex.synchronize { @running[user_id] >= limit || @active >= ACTIVE_LIMIT }
    end

    def acquire(user_id)
      @mutex.synchronize do
        @cond.wait(@mutex) while @running[user_id] >= limit || @active >= ACTIVE_LIMIT
        @running[user_id] += 1
        @active += 1
      end
    end

    def release(user_id)
      @mutex.synchronize do
        @running[user_id] -= 1
        @active -= 1 if @active.positive?
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
        delete_queued_notice(bot, msg, queued_msg)
        yield
      end
    end

    private

    def delete_queued_notice(bot, msg, queued_msg)
      bot.delete_message(msg, queued_msg.message_id) if queued_msg
    rescue StandardError
      nil
    end
  end
end
