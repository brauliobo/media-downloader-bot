class Downloader
  attr_reader :processor

  def initialize(processor)
    @processor = processor
  end

  # Delegate unknown calls to the original Processor instance so subclasses can
  # reuse its state (opts, url, dir, etc.) without boilerplate.
  def method_missing(m, *args, &blk)
    return processor.public_send(m, *args, &blk) if processor.respond_to?(m)
    super
  end

  def respond_to_missing?(m, include_private = false)
    processor.respond_to?(m, include_private) || super
  end
end
