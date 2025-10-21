module Downloaders
  REGISTRY = []

  def self.register(klass)
    REGISTRY << klass unless REGISTRY.include?(klass)
  end

  def self.for(processor)
    # Prefer specific downloaders over the generic yt-dlp one
    klass = REGISTRY.find { |k| k != Downloaders::YtDlp && k.respond_to?(:supports?) && k.supports?(processor) }
    (klass || Downloaders::YtDlp).new(processor)
  end
end

require_relative 'downloaders/base'
require_relative 'downloaders/kindle'
require_relative 'downloaders/telegram'
require_relative 'downloaders/yt_dlp'
