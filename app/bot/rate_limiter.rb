module Bot
  module RateLimiter
    extend ActiveSupport::Concern

    # What Telegram allows (core.telegram.org/bots/faq): a message a second to one chat, 20 a minute to one group, 30 a second in all.
    GLOBAL_INTERVAL = 1.0 / 30
    PRIVATE_INTERVAL = 1.0
    GROUP_INTERVAL   = 3.0

    class Scheduler
      def initialize(interval)
        @interval  = interval
        @mutex     = Mutex.new
        @condition = ConditionVariable.new
        @next_at   = 0.0
        @pending   = {}
      end

      def wait
        delay = @mutex.synchronize { reserve }
        sleep delay if delay.positive?
      end

      def edit(key, force: false, &operation)
        return force_edit(key, operation) if force

        immediate = @mutex.synchronize do
          if @pending.empty? && @next_at <= clock
            reserve
            true
          else
            @pending[key] = operation
            start_worker
            @condition.signal
            false
          end
        end
        immediate ? operation.call : :queued
      end

      def stop
        @worker&.kill
      end

      private

      def force_edit(key, operation)
        delay = @mutex.synchronize do
          @pending.delete(key)
          reserve
        end
        sleep delay if delay.positive?
        operation.call
      end

      def reserve
        now     = clock
        send_at = [@next_at, now].max
        @next_at = send_at + @interval
        send_at - now
      end

      # The worker leaves when nothing is pending (it is set to nil under the lock, where `edit` starts it), so a chat that went quiet holds no thread.
      def start_worker
        return if @worker

        @worker = Thread.new do
          while (operation = next_edit)
            begin
              operation.call
            rescue => e
              warn "Telegram edit failed: #{e.class}: #{e.message}"
            end
          end
        end
      end

      def next_edit
        @mutex.synchronize do
          loop do
            if @pending.empty?
              @worker = nil
              return
            elsif (delay = @next_at - clock).positive?
              @condition.wait(@mutex, delay)
            else
              _, operation = @pending.shift
              @next_at = clock + @interval
              return operation
            end
          end
        end
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # One scheduler per chat, at the pace Telegram gives it (a group's is slower than a private chat's), and one for all of them: a chat
    # that is held back, a group with many books editing their status, holds back nobody else.
    class Limits
      def initialize(global: GLOBAL_INTERVAL, private_chat: PRIVATE_INTERVAL, group: GROUP_INTERVAL)
        @global = Scheduler.new(global)
        @chats  = Hash.new { |chats, id| chats[id] = Scheduler.new(id.to_i.negative? ? group : private_chat) }
        @mutex  = Mutex.new
      end

      def wait(chat_id = nil)
        chat(chat_id)&.wait
        @global.wait
      end

      def edit(chat_id, key, force: false, &operation) = chat(chat_id).edit(key, force: force) { @global.wait; operation.call }

      def stop = [@global, *@mutex.synchronize { @chats.values }].each(&:stop)

      private

      def chat(id) = (@mutex.synchronize { @chats[id] } unless id.nil?)
    end

    included do
      class_attribute :telegram_scheduler
      self.telegram_scheduler = Limits.new
    end

    # `chat_id` is the chat the message goes to; without it only the overall limit applies.
    def throttle!(chat_id = nil)
      telegram_scheduler.wait(chat_id)
    end

    def throttle_edit(chat_id, message_id, force: false, &operation)
      telegram_scheduler.edit(chat_id, [chat_id, message_id], force: force, &operation)
    end

    def with_rate_limit(tag)
      yield
    rescue => e
      raise unless rate_limited?(e)
      ra = retry_after_seconds(e)
      log_rate_limit(tag, ra)
      sleep ra
      raise
    end

    # Also asked by a worker, of the error the bot answered its call with.
    def self.rate_limited?(error) = error.message.to_s.then { |msg| msg.include?('429') || msg.include?('Too Many Requests') }

    def self.response_body(error) = error.try(:response).try(:body)

    def self.retry_after_seconds(error)
      retry_after = error.message.to_s[/retry after (\d+(?:\.\d+)?)/i, 1]
      return retry_after.to_f.ceil if retry_after

      parsed = JSON.parse(response_body(error).to_s) rescue {}
      seconds = (parsed.dig('parameters', 'retry_after') || parsed.dig('error', 'retry_after')).to_i
      seconds.positive? ? seconds : 60
    end

    def rate_limited?(error) = RateLimiter.rate_limited?(error)

    def retry_after_seconds(error) = RateLimiter.retry_after_seconds(error)

    def response_body(error) = RateLimiter.response_body(error)

    def log_rate_limit(tag, seconds)
      msg = "[RATE_LIMIT] sleeping #{seconds}s (#{tag})"
      respond_to?(:dlog, true) ? dlog(msg) : warn(msg)
    end
  end
end
