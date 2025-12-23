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
        url: processor.url,
        opts: processor.opts,
        dir: processor.dir,
        tmp: processor.tmp,
        st: processor.st,
        session: processor.session,
        msg: processor.msg,
        stl: processor.stl
      )
    end

    # Prefer specific downloaders over the generic yt-dlp one
    klass = REGISTRY.find { |k| k != Downloaders::YtDlp && k.respond_to?(:supports?) && k.supports?(ctx) }
    (klass || Downloaders::YtDlp).new(ctx)
  end
end

require_relative 'downloaders/base'
require_relative 'downloaders/kindle'
require_relative 'downloaders/telegram'
require_relative 'downloaders/yt_dlp'
