require_relative '../job_pool'

Thread.report_on_exception = true
Thread.abort_on_exception  = true

module Enumerable
  PEACH_THREADS = :peach_threads
  DEFAULT_THREADS = 10

  def self.default_threads
    ENV['THREADS'] || DEFAULT_THREADS
  end

  def self.thread_count(*candidates, default: default_threads)
    (candidates.find { !_1.nil? } || default).to_i
  end

  def self.peach_threads(explicit = nil)
    thread_count(Thread.current[PEACH_THREADS], explicit)
  end

  def self.admin_threads(admin, threads = nil)
    admin ? thread_count(threads) : 1
  end

  def self.with_peach_threads(threads)
    previous = Thread.current[PEACH_THREADS]
    Thread.current[PEACH_THREADS] = threads
    yield
  ensure
    Thread.current[PEACH_THREADS] = previous
  end

  def peach method = :each, threads: nil, priority: nil, reraise: false, wait: true, &block
    block   ||= -> *args {}
    context = Enumerable.peach_threads(threads)
    threads = context

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
    context = Enumerable.thread_count(threads, Thread.current[PEACH_THREADS], default: ENV['API_THREADS'] || 3)
    Enumerable.with_peach_threads(context) do
      peach(method, threads: context, priority: priority, &block)
    end
  end

  def cpu_peach method = :each, threads: nil, priority: nil, &block
    context = Enumerable.thread_count(Thread.current[PEACH_THREADS], threads, default: ENV['CPU_THREADS'])
    Enumerable.with_peach_threads(context) do
      peach(method, threads: context, priority: ENV['CPU_PRIORITY']&.to_i, &block)
    end
  end

end

require_relative '../pipeline'
