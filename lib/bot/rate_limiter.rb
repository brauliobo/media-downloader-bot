require 'limiter'
require 'active_support/concern'

module Bot
  module RateLimiter
    extend ActiveSupport::Concern

    included do
      class_attribute :rate_limiter_global, :rate_limiter_chats
      class_attribute :rl_mutex, :send_waiting_global, :send_waiting_by_chat
      class_attribute :msg_edit_next_allowed_by_message, :edit_discard_interval_secs

      self.rl_mutex = Mutex.new
      self.send_waiting_global = 0
      self.send_waiting_by_chat = Hash.new(0)
      self.msg_edit_next_allowed_by_message = Hash.new(0.0)
      self.edit_discard_interval_secs = 1.0
    end

    class_methods do
      def rate_limits(global:, per_chat:)
        self.rate_limiter_global = Limiter::RateQueue.new(global, interval: 1)
        self.rate_limiter_chats  = Hash.new { |h, k| h[k] = Limiter::RateQueue.new(per_chat, interval: 1) }
      end
    end

    def throttle!(chat_id, priority = :high, discard: false, message_id: nil)
      if priority == :high
        with_wait(chat_id) { shift_both(chat_id) }
      else
        return :discard if discard && message_id && !allow_edit?(message_id)
        sleep 0.02 while busy?(chat_id)
        shift_both(chat_id)
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
      begin
        yield
      ensure
        rl_mutex.synchronize { self.send_waiting_global -= 1; self.send_waiting_by_chat[chat_id] -= 1 }
      end
    end

    def busy?(chat_id)
      rl_mutex.synchronize { send_waiting_global.positive? || send_waiting_by_chat[chat_id].positive? }
    end

    def shift_both(chat_id)
      rate_limiter_chats[chat_id].shift; rate_limiter_global.shift
    end

    def allow_edit?(message_id)
      return true unless message_id
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      interval = edit_discard_interval_secs.to_f.positive? ? edit_discard_interval_secs.to_f : 1.0
      rl_mutex.synchronize do
        next_at = msg_edit_next_allowed_by_message[message_id]
        return false if now < next_at
        msg_edit_next_allowed_by_message[message_id] = now + interval
        true
      end
    end
  end
end


