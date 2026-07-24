require 'concurrent'

class JobPool
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
        Thread.current.priority = priority if priority
        block.call(item)
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
      completed = false

      items.each_with_index do |item, index|
        pool.post do
          Thread.current.priority = priority if priority
          result = begin
            {value: block.call(item)}
          rescue => error
            {error: error}
          end
          mutex.synchronize do
            results[index] = result
            condition.broadcast
          end
        end
      end
      pool.shutdown

      items.each_index do |index|
        result = mutex.synchronize do
          condition.wait(mutex) while results[index].nil?
          results[index]
        end
        raise result[:error] if result[:error]

        output << result[:value]
      end
      completed = true
    ensure
      pool&.kill unless completed
      pool&.wait_for_termination
    end
  end
end
