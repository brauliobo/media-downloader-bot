require 'securerandom'

module Bot
  class JobCancelled < Interrupt
  end

  Callback = Struct.new(:id, :user_id, :chat_id, :message_id, :data, keyword_init: true)

  class Jobs
    CANCEL_PREFIX = 'job:cancel:'.freeze

    attr_reader :queue

    def initialize(queue: Queue.new)
      @queue = queue
      @jobs  = {}
      @mutex = Mutex.new
    end

    def submit(msg)
      id   = SecureRandom.urlsafe_base64(12)
      data = msg.respond_to?(:to_h) ? msg.to_h.except(:bot, :resp) : msg
      job = {
        id:       id,
        owner_id: msg.from.id,
        chat_id:  msg.chat.id,
        message:  data,
      }

      @mutex.synchronize do
        @jobs[id] = {owner_id: job[:owner_id], chat_id: job[:chat_id], cancelled: false}
      end
      queue.enq(job)
      job
    end

    def dequeue(timeout: nil)
      queue.deq(timeout: timeout)
    end

    def size
      queue.size
    end

    def cancel(id, user_id:, chat_id:, admin: false)
      @mutex.synchronize do
        job = @jobs[id.to_s]
        return :not_found unless job
        owner = job[:owner_id].to_i == user_id.to_i && job[:chat_id].to_i == chat_id.to_i
        return :forbidden unless admin || owner
        return :already_cancelled if job[:cancelled]

        job[:cancelled] = true
        :cancelled
      end
    end

    def cancelled?(id)
      @mutex.synchronize { @jobs.dig(id.to_s, :cancelled) == true }
    end

    def finish(id)
      @mutex.synchronize { @jobs.delete(id.to_s) }
      true
    end

    def self.cancel_data(id)
      "#{CANCEL_PREFIX}#{id}"
    end

    def self.cancel_id(data)
      value = data.to_s
      value.delete_prefix(CANCEL_PREFIX) if value.start_with?(CANCEL_PREFIX)
    end
  end
end
