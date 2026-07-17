require_relative '../utils/duration'
require_relative '../utils/mime_types'
require 'active_support/core_ext/module/delegation'
require_relative '../output'
require_relative '../utils/input_parser'
require_relative '../context'

module Processors
  class Base
    BLOCKED_DOMAINS = ENV.fetch('BLOCKED_DOMAINS', '').split.map { |host| host.downcase.delete_prefix('.') }.freeze

    attr_reader :ctx
    delegate :msg, :st, :dir, :tmp, :url, :opts, :session, to: :ctx
    attr_reader :stl

    # Maintain backward compatibility for readers if needed, but prefer delegating to ctx
    def args; @args; end

    def initialize(ctx)
      @ctx = ctx
      @ctx.tmp ||= Dir.mktmpdir('input-', ctx.dir)
      @stl = ctx.stl
      
      parse_input if ctx.msg || ctx.line
    end

    def stl=(v)
      @stl = v
      ctx.stl = v
    end

    def parse_input
      line = Utils::InputParser.input_text(ctx)
      return if line.blank?
      
      parsed = Utils::InputParser.parse(line)
      @ctx.url = parsed.url&.to_s
      
      if parsed.url&.host
        host = parsed.url.host.downcase.delete_suffix('.')
        raise 'Blocked domain' if BLOCKED_DOMAINS.any? { |domain| host.include?(domain) }
      end

      @ctx.opts = SymMash.new(parsed.opts.merge(session: @ctx.session))
      self.class.expand_lang_opt @ctx.opts
      self.class.apply_process_opts @ctx.opts
      @args = [] # Deprecated but kept for safety if child classes use it
    end

    def process(*args, **kwargs)
      result = download(*args, **kwargs) if respond_to?(:download)
      raise NotImplementedError, "process not implemented" unless result
      Array.wrap(result).each{ |r| r.processor = self }
      result
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

    # Backwards-compatible option parser used by CLI wrappers (e.g. bin/zip, mediazip).
    # Supports:
    # - flags: "audio" => opts.audio = 1
    # - key/values: "lang=pt" => opts.lang = "pt"
    # - metadata: "meta.artist=Foo" / "metadata.title=Bar" / "artist=Foo" (common tags)
    def self.add_opt(opts, raw)
      return opts unless opts && raw
      s = raw.to_s.strip
      return opts if s.empty?

      k, v = s.split('=', 2)
      v = 1 if v.nil?

      key = k.to_s.strip
      return opts if key.empty?

      meta_prefix = key.start_with?('meta.') || key.start_with?('metadata.')
      meta_key = meta_prefix ? key.split('.', 2).last : key

      common_meta = %w[title artist album performer genre date comment track]
      if key == 'album' && v == 1
        opts[:album] = 1
      elsif meta_prefix || common_meta.include?(meta_key)
        opts[:metadata] ||= SymMash.new
        opts[:metadata][meta_key.to_sym] = v
      else
        opts[key.to_sym] = v
      end

      expand_lang_opt opts if key == 'lang'
      apply_process_opts opts if key == 'nice'
      opts
    end

    def self.expand_lang_opt(opts)
      return unless (lang = opts.delete(:lang))
      opts.slang ||= lang
      opts.alang ||= lang
    end

    def self.apply_process_opts(opts)
      apply_nice opts[:nice] if opts&.key?(:nice)
    end

    def self.apply_nice(value)
      Process.setpriority(Process::PRIO_PROCESS, 0, [[value.to_i, 19].min, -20].max)
    end

    protected

    def init_params
      { dir: dir, msg: msg, st: st, stline: stl }
    end

  end
end
