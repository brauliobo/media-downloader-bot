require 'taglib'
require 'chronic_duration'

class Bot
  class Processor

    include Zipper

    VID_DURATION_THLD = 35
    AUD_DURATION_THLD = 80

    VID_TOO_LONG = "\nQuality is compromised as the video is too long to fit the #{SIZE_MB_LIMIT}MB upload limit on Telegram Bots"
    AUD_TOO_LONG = "\nQuality is compromised as the audio is too long to fit the #{SIZE_MB_LIMIT}MB upload limit on Telegram Bots"
    VID_TOO_BIG  = "\nVideo over #{SIZE_MB_LIMIT}MB Telegram Bot's limit, converting to audio..."
    TOO_BIG      = "\nFile over #{SIZE_MB_LIMIT}MB Telegram Bot's limit"

    # missing mimes
    Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'
    Rack::Mime::MIME_TYPES['.mkv']  = 'video/x-matroska'
    Rack::Mime::MIME_TYPES['.caf']  = 'audio/x-caf'

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


    def initialize bot, msg, dir
      @bot = bot
      @msg = msg
      @dir = dir
    end

    def handle_input i
      return input.merge! fn_out: 'fake' if i.opts.simulate

      self.class.probe i
      unless i.type
        edit_message msg, msg.resp.result.message_id, text: me("Unknown type for #{i.fn_in}")
        return
      end

      # FIXME: specify different levels depending on length
      if i.type == Types.video and i.durat > VID_DURATION_THLD.minutes.to_i
        i.opts.width ||= 480
        edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me(VID_TOO_LONG))
      end
      if i.type == Types.audio and i.durat > AUD_DURATION_THLD.minutes.to_i
        i.opts.bitrate ||= 0.98 * 8 * (SIZE_MB_LIMIT*1000) / i.durat
        edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me(AUD_TOO_LONG))
      end

      binding.pry if ENV['PRY_BEFORE_CONVERT']

      if skip_convert? i.type, i.probe, i.opts
        i.fn_out = i.fn_in
      else
        i.fn_out = convert i
        return unless i.fn_out
      end

      # check telegram bot's upload limit
      mbsize = File.size(i.fn_out) / 2**20
      if i.type == Types.video and mbsize >= SIZE_MB_LIMIT
        edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me(VID_TOO_BIG))
        i.type   = Types.audio
        i.fn_out = convert i
        mbsize   = File.size(i.fn_out) / 2**20
      end
      # still too big as audio...
      if mbsize >= SIZE_MB_LIMIT
        edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me(TOO_BIG))
        return
      end

      tag i.fn_out, i.info

      i
    end

    def tag fn, info
      return # using FFmpeg
      TagLib::FileRef.open fn do |f|
        return if f&.tag.nil?
        f.tag.title   = info.title
        f.tag.artist  = info.uploader
        f.tag.comment = info.info.original_url
        f.save
      end
    end

    def skip_convert? type, probe, opts
      return if opts.bitrate # custom bitrate
      stream = probe.streams.first
      return true if type.name == :audio and stream.codec_name == 'aac' and stream.bit_rate.to_i/1000 < Types.audio.opts.bitrate
      false
    end

    def convert i
      i.format = i.type[i.opts.format || i.type[:default]]
      i.opts.format = i.format

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

      o, e, st = send "zip_#{i.type.name}", i.fn_in, fn_out, opts: i.opts, probe: i.probe
      if st != 0
        edit_message msg, msg.resp.result.message_id, text: (msg.resp.text << me("\nConvert failed: #{o}\n#{e}"))
        admin_report msg, "#{o}\n#{e}", status: 'Convert failed'
        return
      end

      fn_out
    end

  end
end
