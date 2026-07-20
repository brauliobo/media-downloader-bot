module Bot
  module RateLimiter
    extend ActiveSupport::Concern

    DEFAULT_SEND_INTERVAL = 1.0

    included do
      class_attribute :rate_limit_mutex, :next_send_at, :send_interval
      self.rate_limit_mutex = Mutex.new
      self.next_send_at     = 0.0
      self.send_interval    = ENV.fetch('TELEGRAM_MESSAGE_INTERVAL', DEFAULT_SEND_INTERVAL).to_f
    end

    def throttle!(_chat_id, _priority = :high, discard: false, message_id: nil)
      rate_limit_mutex.synchronize do
        now  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        wait = self.class.next_send_at - now
        return :discard if discard && wait.positive?

        sleep wait if wait.positive?
        self.class.next_send_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + send_interval
      end
    end

    def retry_after_seconds(e)
      ra = e.message[/retry after (\d+(?:\.\d+)?)/, 1]
      return ra.to_f.ceil if ra
      body = JSON.parse(e.response.body)
      (body.dig('parameters', 'retry_after') || body.dig('error', 'retry_after')).to_i
    end
  end
end
