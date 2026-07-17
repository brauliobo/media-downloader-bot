require_relative 'context'

module Downloaders
  REGISTRY = []

  def self.register(klass)
    REGISTRY << klass unless REGISTRY.include?(klass)
  end

  def self.for(processor)
    ctx = if processor.respond_to?(:ctx)
      processor.ctx
    else
      Context.new(
        url:     processor.url,
        opts:    processor.opts,
        dir:     processor.dir,
        tmp:     processor.tmp,
        st:      processor.st,
        session: processor.session,
        service: (processor.service if processor.respond_to?(:service)),
        msg:     processor.msg,
        stl:     processor.stl
      )
    end

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
