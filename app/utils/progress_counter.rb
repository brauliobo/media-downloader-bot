require 'thread'

module Utils
  class ProgressCounter
    attr_reader :count

    # `done` is what an earlier run already did: it counts, so the progress of a resumed job is the job's, not the run's.
    def initialize(total:, done: 0, status: nil, &format)
      @total  = total
      @status = status
      @format = format
      @count  = done
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
