require 'chronic_duration'

class Bot
  class Processor

    Types = Zipper::Types

    VID_DURATION_THLD = if Zipper.size_mb_limit then 35 else Float::INFINITY end
    AUD_DURATION_THLD = if Zipper.size_mb_limit then Zipper.max_audio_duration Zipper::Types.audio.opus.opts.bitrate else Float::INFINITY end

    VID_TOO_LONG = "\nQuality is compromised as the video is too long to fit the #{Zipper.size_mb_limit}MB upload limit on Telegram Bots"
    AUD_TOO_LONG = "\nQuality is compromised as the audio is too long to fit the #{Zipper.size_mb_limit}MB upload limit on Telegram Bots"
    VID_TOO_BIG  = "\nVideo over #{Zipper.size_mb_limit}MB Telegram Bot's limit, converting to audio..."
    TOO_BIG      = "\nFile over #{Zipper.size_mb_limit}MB Telegram Bot's limit"

    # missing mimes
    Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'
    Rack::Mime::MIME_TYPES['.flac'] = 'audio/x-flac'
    Rack::Mime::MIME_TYPES['.caf']  = 'audio/x-caf'
    Rack::Mime::MIME_TYPES['.mkv']  = 'video/x-matroska'

    attr_reader :bot
    attr_reader :msg
    attr_reader :dir

    delegate_missing_to :bot

    def self.probe i
      i.probe  = Prober.for i.fn_in
      i.durat  = i.probe.format.duration.to_i
      i.durat -= ChronicDuration.parse i.opts.ss if i.opts.ss
      mtype  = Rack::Mime.mime_type File.extname i.fn_in
      i.type = if mtype.index 'video' then Types.video elsif mtype.index 'audio' then Types.audio end
      i.type = Types.audio if i.opts.audio
      i
    end

    def initialize dir, bot, msg=nil
      @dir = dir
      @bot = bot
      @msg = msg || bot.fake_msg
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

    def handle_input i
      return input.merge! fn_out: 'fake' if i.opts.simulate

      self.class.probe i
      unless i.type
        edit_message msg, msg.resp.result.message_id, text: me("Unknown type for #{i.fn_in}")
        return
      end

      if Zipper.size_mb_limit
        # FIXME: specify different levels depending on length
        if i.type == Types.video and i.durat > VID_DURATION_THLD.minutes.to_i
          i.opts.width ||= 480
          edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me(VID_TOO_LONG))
        end
        if i.type == Types.audio and i.durat > AUD_DURATION_THLD.minutes.to_i
          edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me(AUD_TOO_LONG))
        end
      end

      binding.pry if ENV['PRY_BEFORE_CONVERT']

      i.thumb = i.opts.thumb = thumb i.info
      return unless i.fn_out = convert(i)

      # check telegram bot's upload limit
      if Zipper.size_mb_limit
        mbsize = File.size(i.fn_out) / 2**20
        if i.type == Types.video and mbsize >= Zipper.size_mb_limit
          edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me(VID_TOO_BIG))
          i.type   = Types.audio
          i.fn_out = convert i
          mbsize   = File.size(i.fn_out) / 2**20
        end
        # still too big as audio...
        if mbsize >= Zipper.size_mb_limit
          edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me(TOO_BIG))
          return
        end
      end

      tag i

      i
    end
    
    def tag i
      Tagger.add_cover i.fn_out, i.thumb if i.thumb and i.type == Types.audio
      # ... the rest is using FFmpeg
    end

    THUMB_MAX_HEIGHT = 320
    THUMB_RESIZE_CMD = "convert %{in} %{opts} -define jpeg:extent=190kb %{out}"

    def thumb info
      return if (url = info.thumbnail).blank?

      im_in  = "#{dir}/img"
      im_out = "#{dir}/#{info._filename}-thumb.jpg"
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

    def convert i
      speed    = i.opts.speed&.to_f
      durat    = i.durat
      durat   /= speed if speed
      durat   -= ChronicDuration.parse i.opts.ss if i.opts.ss
      format   = i.opts.format || i.type[:default]
      format   = :aac if format == :opus and durat < 120 if Zipper.size_mb_limit # telegram consider small opus as voice
      i.format = i.opts.format = i.type[format]
      i.opts.cover  = i.info.thumbnail

      m = SymMash.new
      m.artist = i.info.uploader
      m.title  = i.info.title
      m.file   = File.basename i.fn_in
      m.url    = i.url
      i.opts.metadata = m

      fn_out  = i.info.title.dup
      fn_out << " by #{i.info.uploader}" if i.info.uploader
      fn_out  = fn_out.first 80 # /tmp can't have big filename
      fn_out << ".#{i.format.ext}"
      fn_out.gsub! '"', '' # Telegram doesn't accept "
      fn_out.gsub! '/', ', ' # not escaped by shellwords
      fn_out  = "#{dir}/#{fn_out}"

      o, e, st = Zipper.send "zip_#{i.type.name}", i.fn_in, fn_out, opts: i.opts, probe: i.probe
      if st != 0
        edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me("\nConvert failed: #{o}\n#{e}"))
        admin_report msg, "#{o}\n#{e}", status: 'Convert failed'
        return
      end

      fn_out
    end

    protected

    def http
      Mechanize.new
    end

  end
end
