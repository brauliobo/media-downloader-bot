require 'chronic_duration'
require_relative '../output'

class Bot
  class Processor

    def self.add_opt h, o
      k, v = o.split('=', 2)
      h[k] = v || 1
    end

    Types = Zipper::Types

    VID_TOO_LONG = -> { "\nQuality is compromised as the video is too long to fit the #{Zipper.size_mb_limit}MB upload limit on Telegram Bots" }
    AUD_TOO_LONG = -> { "\nQuality is compromised as the audio is too long to fit the #{Zipper.size_mb_limit}MB upload limit on Telegram Bots" }
    VID_TOO_BIG  = -> { "\nVideo over #{Zipper.size_mb_limit}MB Telegram Bot's limit" }
    TOO_BIG      = -> { "\nFile over #{Zipper.size_mb_limit}MB Telegram Bot's limit" }

    # missing mimes
    Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'
    Rack::Mime::MIME_TYPES['.flac'] = 'audio/x-flac'
    Rack::Mime::MIME_TYPES['.caf']  = 'audio/x-caf'
    Rack::Mime::MIME_TYPES['.aac']  = 'audio/x-aac'
    Rack::Mime::MIME_TYPES['.mkv']  = 'video/x-matroska'

    BLOCKED_DOMAINS = ENV['BLOCKED_DOMAINS'].split.map{ |u| URI.parse u }

    attr_reader :bot
    attr_reader :msg
    attr_reader :st
    attr_reader :dir, :tmp

    attr_reader :args
    attr_reader :url
    attr_reader :opts

    delegate_missing_to :bot

    def self.probe i
      mtype  = Rack::Mime.mime_type File.extname i.fn_in
      return i unless mtype&.match?(/audio|video/)

      i.probe  = Prober.for i.fn_in
      i.durat  = i.probe.format.duration.to_i
      i.durat -= ChronicDuration.parse i.opts.ss if i.opts.ss
      i.type = if mtype.index 'video' then Types.video elsif mtype.index 'audio' then Types.audio end
      i.type = Types.audio if i.opts.audio
      i
    end

    def initialize dir:, bot:,
      msg: nil, line: nil,
      st: nil, stline: nil, **params

      @dir  = dir
      @tmp  = Dir.mktmpdir 'input-', dir
      @bot  = bot
      @msg  = msg || bot.fake_msg
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

    def cleanup
      return if ENV['TMPDIR']
      FileUtils.remove_entry tmp
    end

    def input_from_file f, opts
      SymMash.new(
        fn_in: f,
        opts:  opts,
        info:  {
          title: File.basename(f, File.extname(f)),
        },
      )
    end

    def handle_input i, pos: nil
      raise 'no input provided' unless i
      return input.merge! fn_out: 'fake' if i.opts.simulate

      self.class.probe i
      return @stl&.error "Unknown type for #{i.fn_in}" unless i.type

      if Zipper.size_mb_limit
        if i.type == Types.video and i.durat > Zipper.vid_duration_thld.minutes.to_i
          @stl.update VID_TOO_LONG[]
        end
        if i.type == Types.audio and i.durat > Zipper.aud_duration_thld.minutes.to_i
          @stl.update AUD_TOO_LONG[]
        end
      end

      binding.pry if ENV['PRY_BEFORE_CONVERT']

      # Handle subtitle-only request before heavy conversion
      if i.opts.onlysrt
        generate_srt_only(i)
        return i
      end

      i.thumb = i.opts.thumb = thumb i.info
      return unless i.fn_out = convert(i, pos: pos)

      # check telegram bot's upload limit
      if Zipper.size_mb_limit
        mbsize = File.size(i.fn_out) / 2**20
        return @stl.error VID_TOO_BIG[] if i.type == Types.video and mbsize >= Zipper.size_mb_limit
        return @stl.error TOO_BIG[] if mbsize >= Zipper.size_mb_limit
      end

      tag i

      i
    end

    def generate_srt_only i
      srt_path = Zipper.generate_srt(i.fn_in, dir: dir, info: i.info, probe: i.probe, stl: @stl, opts: i.opts)
      i.uploads = [SymMash.new(path: srt_path, mime: 'application/x-subrip', caption: '')]
    end

    def tag i
      Tagger.add_cover i.fn_out, i.thumb if i.thumb and i.type == Types.audio
      # ... the rest is using FFmpeg
    end

    THUMB_MAX_HEIGHT = 320
    THUMB_RESIZE_CMD = "convert %{in} %{opts} -define jpeg:extent=190kb %{out}"

    def thumb info
      return if (url = info.thumbnail).blank?

      im_in  = "#{info._filename}-ithumb.jpg"
      im_out = "#{info._filename}-othumb.jpg"
      File.write im_in, http.get(url).body

      opts = if portrait? info
        w,h = THUMB_MAX_HEIGHT * info.width/info.height, THUMB_MAX_HEIGHT
        "-resize #{w}x#{h}\^ -gravity Center -extent #{w}x#{h}"
      else
        "-resize x#{THUMB_MAX_HEIGHT}"
      end
      Sh.run THUMB_RESIZE_CMD % {in: im_in, out: im_out, opts: opts}

      im_out
    rescue => e # continue on errors
      report_error msg, e
      nil
    end

    def portrait? info
      return unless info.width
      info.width < info.height
    end

    def convert i, pos: nil
      speed    = i.opts.speed&.to_f
      durat    = i.durat
      durat   /= speed if speed
      durat   -= ChronicDuration.parse i.opts.ss if i.opts.ss

      chosen   = Zipper.choose_format i.type, i.opts, durat

      i.format = i.opts.format = chosen
      i.opts.cover  = i.info.thumbnail

      m = SymMash.new
      m.artist = i.info.uploader
      m.title  = i.info.title
      m.file   = File.basename i.fn_in
      m.url    = i.url
      i.opts.metadata = m

      fn_out = Output.filename(i.info, dir: dir, ext: i.format.ext, pos: pos)

      Dir.chdir dir do
        o, e, st = Zipper.send "zip_#{i.type.name}", i.fn_in, fn_out,
          opts: i.opts, probe: i.probe, stl: @stl, info: i.info
        if st != 0
          @stl.error "convert failed: #{o}\n#{e}"
          return
        end
      end

      fn_out
    end

    protected

    def http
      Mechanize.new
    end

  end
end
