require 'chronic_duration'
require 'rack/mime'
require_relative '../output'

module Processors
  class Base

    def self.add_opt h, o
      k, v = o.split('=', 2)
      h[k] = v || 1
    end

    # missing mimes
    Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'
    Rack::Mime::MIME_TYPES['.flac'] = 'audio/x-flac'
    Rack::Mime::MIME_TYPES['.caf']  = 'audio/x-caf'
    Rack::Mime::MIME_TYPES['.aac']  = 'audio/x-aac'
    Rack::Mime::MIME_TYPES['.mkv']  = 'video/x-matroska'

    BLOCKED_DOMAINS = (ENV['BLOCKED_DOMAINS'] || '').split.map{ |u| URI.parse u }

    attr_reader :msg
    attr_reader :st
    attr_reader :dir, :tmp

    attr_reader :args
    attr_reader :url
    attr_reader :opts
    attr_accessor :stl

    def initialize dir:,
      msg: nil, line: nil,
      st: nil, stline: nil, **params

      @dir  = dir
      @tmp  = Dir.mktmpdir 'input-', dir
      @msg  = msg || MsgHelpers.fake_msg
      @st   = st || stline.status
      @stl  = stline

      return unless line || msg
      @line = line || msg&.text
      if @line.blank?
        @args = []
        @opts = SymMash.new
        return
      end
      @args = @line.split(/[[:space:]]+/)
      @uri  = Addressable::URI.parse(@args.shift) if @args.first&.match?(URI::DEFAULT_PARSER.make_regexp)
      @url  = @uri&.to_s
      raise 'Blocked domain' if @uri && @uri.host && BLOCKED_DOMAINS.any?{ |d| @uri.host.index d }

      @opts = @args.each.with_object SymMash.new do |a, h|
        self.class.add_opt h, a
      end
    end

    def process(*args, **kwargs)
      result = download(*args, **kwargs) if respond_to?(:download)
      raise NotImplementedError, "process not implemented" unless result
      Array.wrap(result).each{ |r| r.processor = self }
      result
    ensure
      cleanup
    end

    def cleanup
      return if ENV['TMPDIR']
      FileUtils.remove_entry tmp if ::File.exist?(tmp)
    end

    def input_from_file f, opts
      SymMash.new(
        fn_in: f,
        opts:  opts,
        info:  {
          title: ::File.basename(f, ::File.extname(f)),
        },
      )
    end

    protected

    def init_params
      { dir: dir, msg: msg, line: @line, st: st, stline: @stl }
    end


  end
end
