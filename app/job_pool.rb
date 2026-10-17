require 'concurrent'

class JobPool
  class TaskError < StandardError
    attr_reader :item, :index, :original

    def initialize(item:, index:, original:)
      @item     = item
      @index    = index
      @original = original
      super(original.message)
      set_backtrace(original.backtrace)
    end
  end

  attr_reader :jobs

  def initialize(jobs:)
    raise ArgumentError, 'jobs must be positive' unless jobs.to_i.positive?

    @jobs = jobs.to_i
  end

  def each(items, priority: nil, reraise: false, wait: true, &block)
    errors = Queue.new
    pool   = Concurrent::FixedThreadPool.new(jobs)
    items.each do |item|
      pool.post do
        Bot::JobRestarted.check! # a stop is waited for by the tasks under way, the rest are left for the next run
        Thread.current.priority = priority if priority
        block.call(item)
      rescue Bot::JobRestarted
        nil # raised below, in the caller of the pool: a thread of the pool ending on it would be lost
      rescue => error
        if reraise
          errors << error
        else
          STDERR.puts "error: #{error.message} \n#{error.backtrace.join "\n"}"
        end
      end
    end
    pool.shutdown
    if wait
      pool.wait_for_termination
      Bot::JobRestarted.check!
      raise errors.pop unless errors.empty?
    end
    self
  end

  def ordered_map(items, priority: nil, &block)
    items = items.to_a
    Enumerator.new do |output|
      results   = Array.new(items.size)
      mutex     = Mutex.new
      condition = ConditionVariable.new
      pool      = Concurrent::FixedThreadPool.new(jobs)
      cancelled = false

      items.each_with_index do |item, index|
        pool.post do
          next if cancelled

          Thread.current.priority = priority if priority
          result = begin
            Bot::JobRestarted.check!
            {value: block.call(item)}
          rescue Bot::JobRestarted
            {value: nil} # the consumer raises it at its checkpoint
          rescue => error
            {error: error}
          end
          mutex.synchronize do
            results[index] = result
            condition.broadcast
          end
        end
      end

      items.each_index do |index|
        Bot::JobRestarted.check!
        result = mutex.synchronize do
          condition.wait(mutex) while results[index].nil?
          results[index]
        end
        raise result[:error] if result[:error]

        output << result[:value]
      end
    ensure
      # Tasks not started are skipped; running ones finish. Killing a thread inside a subprocess call closes its pipes
      # under the reader threads, and their IOError would replace the error that stopped the pool.
      cancelled = true
      pool&.shutdown
      pool&.wait_for_termination
    end
  end

  def ordered_each(items, priority: nil, perform:, &consume)
    ordered_map(items.each_with_index, priority: priority) do |item, index|
      value = perform.arity == 1 ? perform.call(item) : perform.call(item, index)
      [item, value, index]
    rescue => error
      raise TaskError.new(item: item, index: index, original: error), cause: error
    end.each do |item, value, index|
      consume.call(item, value, index)
    end
  end
end
