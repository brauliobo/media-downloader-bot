module Downloaders
  # order matters: the first one that builds for the context wins, YtDlp is the fallback
  REGISTRY = [Kindle, Telegram, GalleryDl].freeze

  def self.for(processor)
    ctx = processor.ctx

    REGISTRY.each do |klass|
      downloader = klass.build(ctx)
      return downloader if downloader
    end

    Downloaders::YtDlp.new(ctx)
  end
end
