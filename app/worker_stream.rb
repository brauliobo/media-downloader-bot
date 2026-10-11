# Persistent pool of `size` threads fed through `<<`: a worker takes the next item as soon as it is free, so `size`
# items stay in flight until the feed ends. `<<` blocks while the buffer is full, so the producer can be lazy.
class WorkerStream
  def initialize(size, &work)
    @queue   = SizedQueue.new(size * 2)
    @workers = Array.new(size) { Thread.new { while (item = @queue.pop) do work.call(item) end } }
  end

  def <<(item)
    @queue << item
    self
  end

  # Waits for everything fed so far.
  def close
    @workers.each { @queue << nil }
    @workers.each(&:join)
  end
end
