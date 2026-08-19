require_relative 'job_pool'

class Pipeline
  def self.jobs(tasks = 1)
    [Enumerable.peach_threads / [tasks.to_i, 1].max, 1].max
  end

  def self.each(items, tasks:, perform:, batch: nil, &consume)
    count = jobs(tasks)
    work  = wrap(perform, count)
    return JobPool.new(jobs: count).ordered_each(items, perform: work, &consume) unless batch

    each_batched(items, count: count, batch: batch, perform: work, &consume)
  end

  def self.wrap(perform, count)
    lambda do |item, index|
      Enumerable.with_peach_threads(count) do
        perform.arity == 1 ? perform.call(item) : perform.call(item, index)
      end
    end
  end

  def self.each_batched(items, count:, batch:, perform:, &consume)
    pending = []
    errors  = Queue.new
    pool    = Concurrent::FixedThreadPool.new(count)
    submit  = lambda do |group|
      pool.post do
        Enumerable.with_peach_threads(count) { consume.call(group) }
      rescue => error
        errors << error
      end
    end

    JobPool.new(jobs: count).ordered_each(items, perform: perform) do |item, _|
      pending << item
      submit.call(pending.shift(batch)) if pending.size >= batch
    end
    submit.call(pending) if pending.any?
    pool.shutdown
    pool.wait_for_termination
    raise errors.pop unless errors.empty?
  end
  private_class_method :wrap, :each_batched
end
