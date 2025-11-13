require_relative 'file'
require_relative '../utils/thumb'
require_relative '../zipper'

module Processors
  class Media < File
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

    def self.can_handle?(msg)
      msg.audio.present? || msg.video.present?
    end

    def self.probe i
      return i unless i && i.respond_to?(:fn_in) && i.fn_in.to_s.present?
      mtype  = Rack::Mime.mime_type ::File.extname(i.fn_in.to_s)
      return i unless mtype&.match?(/audio|video/)

      i.probe  = Prober.for i.fn_in
      i.durat  = i.probe.format.duration.to_i
      i.durat -= ChronicDuration.parse i.opts.ss if i.opts.ss
      i.type = if mtype.index 'video' then Types.video elsif mtype.index 'audio' then Types.audio end
      i.type = Types.audio if i.opts.audio
      i
    end


    def handle_input(i, pos: nil, **_kwargs)
      raise 'no input provided' unless i
      return input.merge! fn_out: 'fake' if i.opts.simulate

      # If a downloader already produced uploads, skip further processing
      return i if i.respond_to?(:uploads) && i.uploads.present?

      self.class.probe i
      return @stl&.error "Unknown type for #{i.fn_in}" unless i.type

      if i.opts.genshorts
        Processors::Shorts.new(dir: dir, msg: msg, st: st, stline: @stl).generate_and_upload_shorts(i)
        return i
      end

      if Zipper.size_mb_limit && !opts.onlysrt
        if i.type == Types.video and i.durat > Zipper.vid_duration_thld.minutes.to_i
          @stl.update VID_TOO_LONG[]
        end
        if i.type == Types.audio and i.durat > Zipper.aud_duration_thld.minutes.to_i
          @stl.update AUD_TOO_LONG[]
        end
      end

      binding.pry if ENV['PRY_BEFORE_CONVERT']

      if i.opts.onlysrt
        generate_srt_only(i)
        return i
      end

      i.thumb = i.opts.thumb = Utils::Thumb.process(i.info, base_filename: i.info._filename, on_error: ->(e) { Worker.service.report_error(msg, e)  })
      return unless i.fn_out = convert(i, pos: pos)

      if Zipper.size_mb_limit
        mbsize = ::File.size(i.fn_out) / 2**20
        return @stl.error VID_TOO_BIG[] if i.type == Types.video and mbsize >= Zipper.size_mb_limit
        return @stl.error TOO_BIG[] if mbsize >= Zipper.size_mb_limit
      end

      tag i

      i
    end

    def generate_srt_only i
      srt_path = Zipper.generate_srt(i.fn_in, dir: dir, info: i.info, probe: i.probe, stl: @stl, opts: i.opts)
      i.fn_out = srt_path
      i.type   = SymMash.new(name: :document)
      i.mime   = 'application/x-subrip'
      i.opts.format = SymMash.new(mime: i.mime)
      i.uploads = nil
    end

    def tag i
      Tagger.add_cover i.fn_out, i.thumb if i.thumb and i.type == Types.audio
    end

    def convert i, pos: nil
      speed    = i.opts.speed&.to_f
      durat    = i.durat
      durat   /= speed if speed
      durat   -= ChronicDuration.parse i.opts.ss if i.opts.ss

      chosen   = Zipper.choose_format i.type, i.opts, durat

      i.format = i.opts.format = chosen
      i.mime   = i.format.mime
      i.opts.cover  = i.info.thumbnail

      m = SymMash.new
      m.artist = i.info.uploader
      m.title  = i.info.title
      m.file   = ::File.basename i.fn_in
      m.url    = i.url
      i.opts.metadata = m

      fn_out = ::File.expand_path(Output.filename(i.info, dir: dir, ext: i.format.ext, pos: pos))
      fn_in = ::File.expand_path(i.fn_in)

      o, e, st = Zipper.send "zip_#{i.type.name}", fn_in, fn_out,
        opts: i.opts, probe: i.probe, stl: @stl, info: i.info
      return @stl.error "convert failed: #{o}\n#{e}" if st != 0

      fn_out
    end

  end
end

