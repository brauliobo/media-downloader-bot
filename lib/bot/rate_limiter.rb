require 'limiter'
require 'active_support/concern'

module Bot
  module RateLimiter
    extend ActiveSupport::Concern

    included do
      class_attribute :rate_limiter_global, :rate_limiter_chats
      class_attribute :rl_mutex, :send_waiting_global, :send_waiting_by_chat

      self.rl_mutex = Mutex.new
      self.send_waiting_global = 0
      self.send_waiting_by_chat = Hash.new(0)
    end

    class_methods do
      def rate_limits(global:, per_chat:)
        self.rate_limiter_global = Limiter::RateQueue.new(global, interval: 1)
        self.rate_limiter_chats  = Hash.new { |h, k| h[k] = Limiter::RateQueue.new(per_chat, interval: 1) }
      end
    end

    def throttle!(chat_id, priority = :high, discard: false)
      if priority == :high
        rl_mutex.synchronize { self.send_waiting_global += 1; self.send_waiting_by_chat[chat_id] += 1 }
        begin
          rate_limiter_chats[chat_id].shift; rate_limiter_global.shift
        ensure
          rl_mutex.synchronize { self.send_waiting_global -= 1; self.send_waiting_by_chat[chat_id] -= 1 }
        end
      else
        # If allowed to discard, drop low-priority work when queues are busy
        if discard && rl_mutex.synchronize { send_waiting_global.positive? || send_waiting_by_chat[chat_id].positive? }
          return :discard
        end
        sleep 0.02 while rl_mutex.synchronize { send_waiting_global.positive? || send_waiting_by_chat[chat_id].positive? }
        rate_limiter_chats[chat_id].shift; rate_limiter_global.shift
      end
    end

    def retry_after_seconds(e)
      ra = e.message[/retry after (\d+(?:\.\d+)?)/, 1]
      return ra.to_f.ceil if ra
      begin
        body = JSON.parse(e.response.body)
        (body.dig('parameters', 'retry_after') || body.dig('error', 'retry_after')).to_i
      rescue
        0
      end
    end
  end
end


