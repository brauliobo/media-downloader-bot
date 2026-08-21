module Bot
  module RateLimiter
    extend ActiveSupport::Concern

    DEFAULT_SEND_INTERVAL = 2.0

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

      def start_worker
        return if @worker&.alive?

        @worker = Thread.new do
          loop do
            next_edit.call
          rescue => e
            warn "Telegram edit failed: #{e.class}: #{e.message}"
          end
        end
      end

      def next_edit
        @mutex.synchronize do
          loop do
            if @pending.empty?
              @condition.wait(@mutex)
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

    included do
      class_attribute :telegram_scheduler
      self.telegram_scheduler = Scheduler.new(DEFAULT_SEND_INTERVAL)
    end

    def throttle!
      telegram_scheduler.wait
    end

    def throttle_edit(chat_id, message_id, force: false, &operation)
      telegram_scheduler.edit([chat_id, message_id], force: force, &operation)
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

    def rate_limited?(error)
      msg = error.message.to_s
      msg.include?('429') || msg.include?('Too Many Requests')
    end

    def retry_after_seconds(e)
      retry_after = e.message.to_s[/retry after (\d+(?:\.\d+)?)/i, 1]
      return retry_after.to_f.ceil if retry_after

      body   = e.respond_to?(:response) && e.response.respond_to?(:body) ? e.response.body : nil
      parsed = JSON.parse(body.to_s) rescue {}
      ra     = (parsed.dig('parameters', 'retry_after') || parsed.dig('error', 'retry_after')).to_i
      ra.positive? ? ra : 60
    end

    def log_rate_limit(tag, seconds)
      msg = "[RATE_LIMIT] sleeping #{seconds}s (#{tag})"
      respond_to?(:dlog, true) ? dlog(msg) : warn(msg)
    end
  end
end
