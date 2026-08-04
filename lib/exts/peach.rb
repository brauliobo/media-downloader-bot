require_relative '../job_pool'

Thread.report_on_exception = true
Thread.abort_on_exception  = true

module Enumerable
  PEACH_THREADS = :peach_threads

  def self.with_peach_threads(threads)
    previous = Thread.current[PEACH_THREADS]
    Thread.current[PEACH_THREADS] = threads
    yield
  ensure
    Thread.current[PEACH_THREADS] = previous
  end

  def peach method = :each, threads: nil, priority: nil, reraise: false, wait: true, &block
    block   ||= -> *args {}
    context = Thread.current[PEACH_THREADS] || threads || ENV['THREADS'] || 10
    threads = context.to_i

    if threads == 1
      return Enumerable.with_peach_threads(context) { send(method, &block) }
    end

    arguments = []
    ret = send method do |*args|
      arguments << args
    end
    JobPool.new(jobs: threads).each(arguments, priority: priority, reraise: reraise, wait: wait) do |args|
      Enumerable.with_peach_threads(context) { block.call(*args) }
    end

    ret
  end

  def api_peach method = :each, threads: nil, priority: nil, &block
    context = threads || Thread.current[PEACH_THREADS] || ENV['API_THREADS'] || 3
    Enumerable.with_peach_threads(context) do
      peach(method, threads: context, priority: priority, &block)
    end
  end

  def cpu_peach method = :each, threads: nil, priority: nil, &block
    context = Thread.current[PEACH_THREADS] || threads || ENV['CPU_THREADS']
    Enumerable.with_peach_threads(context) do
      peach(method, threads: context, priority: ENV['CPU_PRIORITY']&.to_i, &block)
    end
  end

end
