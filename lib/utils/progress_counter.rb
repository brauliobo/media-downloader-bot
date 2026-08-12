require 'thread'

module Utils
  class ProgressCounter
    def initialize(total:, status: nil, &format)
      @total  = total
      @status = status
      @format = format
      @count  = 0
      @mutex  = Mutex.new
    end

    def advance(amount = 1)
      @mutex.synchronize do
        @count += amount
        @status&.update @format.call(@count, @total)
      end
    end

    def batch_callback
      ->(batch) { advance(batch.size) }
    end
  end
end
