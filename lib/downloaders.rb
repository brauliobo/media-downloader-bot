require_relative 'context'

module Downloaders
  REGISTRY = []

  def self.register(klass)
    REGISTRY << klass unless REGISTRY.include?(klass)
  end

  def self.for(processor)
    ctx = processor.ctx

    REGISTRY.each do |klass|
      next if klass == Downloaders::YtDlp
      downloader = klass.build(ctx)
      return downloader if downloader
    end

    Downloaders::YtDlp.new(ctx)
  end
end

require_relative 'downloaders/base'
require_relative 'downloaders/kindle'
require_relative 'downloaders/telegram'
require_relative 'downloaders/gallery_dl'
require_relative 'downloaders/yt_dlp'
