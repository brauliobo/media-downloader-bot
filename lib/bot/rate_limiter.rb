require 'limiter'
require 'active_support/concern'

module Bot
  module RateLimiter
    extend ActiveSupport::Concern

    INTERVAL = 60

    included do
      class_attribute :rate_limiter_global, :rate_limiter_chats
      class_attribute :rl_mutex, :send_waiting_global, :send_waiting_by_chat
      class_attribute :last_edit_global, :last_edit_by_chat
      class_attribute :global_rate_limit, :per_chat_rate_limit

      self.rl_mutex = Mutex.new
      self.send_waiting_global = 0
      self.send_waiting_by_chat = Hash.new(0)
      self.last_edit_global = 0.0
      self.last_edit_by_chat = Hash.new(0.0)
    end

    class_methods do
      def rate_limits(global:, per_chat:)
        self.rate_limiter_global = Limiter::RateQueue.new(global, interval: INTERVAL)
        self.rate_limiter_chats  = Hash.new { |h, k| h[k] = Limiter::RateQueue.new(per_chat, interval: INTERVAL) }
        self.global_rate_limit = global
        self.per_chat_rate_limit = per_chat
      end
    end

    def throttle!(chat_id, priority = :high, discard: false, message_id: nil)
      if priority == :high
        with_wait(chat_id) { shift_both(chat_id) }
      else
        if discard
          return :discard if should_discard_edit?(chat_id)
          update_edit_times(chat_id)
        else
          shift_both(chat_id)
        end
      end
    end

    def retry_after_seconds(e)
      ra = e.message[/retry after (\d+(?:\.\d+)?)/, 1]
      return ra.to_f.ceil if ra
      body = JSON.parse(e.response.body)
      (body.dig('parameters', 'retry_after') || body.dig('error', 'retry_after')).to_i
    end

    private

    def with_wait(chat_id)
      rl_mutex.synchronize { self.send_waiting_global += 1; self.send_waiting_by_chat[chat_id] += 1 }
      yield
    ensure
      rl_mutex.synchronize { self.send_waiting_global -= 1; self.send_waiting_by_chat[chat_id] -= 1 }
    end

    def busy?(chat_id)
      rl_mutex.synchronize { send_waiting_global.positive? || send_waiting_by_chat[chat_id].positive? }
    end

    def shift_both(chat_id)
      rate_limiter_chats[chat_id].shift; rate_limiter_global.shift
    end

    def should_discard_edit?(chat_id)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      global_rate = global_rate_limit || 20
      per_chat_rate = per_chat_rate_limit || 10
      global_interval = INTERVAL.to_f / global_rate
      per_chat_interval = INTERVAL.to_f / per_chat_rate
      last_global = last_edit_global
      last_chat = last_edit_by_chat[chat_id]
      (now - last_global) < global_interval || (now - last_chat) < per_chat_interval
    end

    def update_edit_times(chat_id)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rl_mutex.synchronize do
        self.last_edit_global = now
        last_edit_by_chat[chat_id] = now
      end
    end
  end
end


