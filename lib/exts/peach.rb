require_relative '../job_pool'

Thread.report_on_exception = true
Thread.abort_on_exception  = true

module Enumerable

  def peach method = :each, threads: nil, priority: nil, reraise: false, wait: true, &block
    block   ||= -> *args {}
    threads ||= (ENV['THREADS'] || '10').to_i
    threads = threads.to_i

    return send(method, &block) if threads == 1

    arguments = []
    ret = send method do |*args|
      arguments << args
    end
    JobPool.new(jobs: threads).each(arguments, priority: priority, reraise: reraise, wait: wait) do |args|
      block.call(*args)
    end

    ret
  end

  def api_peach method = :each, threads: nil, priority: nil, &block
    peach(method,
      threads:  threads || ENV['API_THREADS'] || 3,
      priority: priority,
      &block
    )
  end

  def cpu_peach method = :each, threads: nil, priority: nil, &block
    peach(method,
      threads:  threads || ENV['CPU_THREADS'],
      priority: ENV['CPU_PRIORITY']&.to_i,
      &block
    )
  end

end
