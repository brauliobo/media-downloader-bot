require 'timeout'

module Processors
  class Media < File
    Types = Zipper::Types
    # file extension => format of what can be uploaded as downloaded
    STREAM_FORMATS = {'.mp4' => Types.video.h264, '.m4a' => Types.audio.aac, '.mp3' => Types.audio.mp3}.freeze

    VID_TOO_LONG = -> { "\nQuality is compromised as the video is too long to fit the #{Zipper.size_mb_limit}MB upload limit on Telegram Bots" }
    AUD_TOO_LONG = -> { "\nQuality is compromised as the audio is too long to fit the #{Zipper.size_mb_limit}MB upload limit on Telegram Bots" }
    VID_TOO_BIG  = -> { "\nVideo over #{Zipper.size_mb_limit}MB Telegram Bot's limit" }
    TOO_BIG      = -> { "\nFile over #{Zipper.size_mb_limit}MB Telegram Bot's limit" }

    def self.can_handle?(msg)
      msg.audio.present? || msg.video.present?
    end

    def self.probe i
      return i unless i && i.respond_to?(:fn_in) && i.fn_in.to_s.present?
      mtype  = Rack::Mime.mime_type ::File.extname(i.fn_in.to_s)

      i.probe  = Prober.for i.fn_in
      raise "probe missing format for #{i.fn_in}" unless i.probe&.format
      source_duration = i.probe.format.duration.to_f
      cuts     = Utils::TimeRanges.parse(i.opts.cuts, option: :cuts).validate!(source_duration, allow_entire: false)
      Utils::TimeRanges.parse(i.opts.silences, option: :silences).validate!(source_duration)
      cut      = Utils::Duration.from_opts(i.opts)
      i.durat  = (cut.finish || source_duration) - cut.start - cuts.total_duration

      # Derive type from MIME if recognized, otherwise fall back to ffprobe streams
      i.type = if mtype&.index('video') then Types.video
               elsif mtype&.index('audio') then Types.audio
               elsif Prober.video_stream?(i.probe) then Types.video
               elsif Prober.audio_stream?(i.probe) then Types.audio
               end
      i.type = Types.audio if i.opts.audio
      i
    end


    def handle_input(i, pos: nil, **_kwargs)
      raise 'no input provided' unless i
      return i.merge!(fn_out: 'fake') if i.opts.simulate

      # If a downloader already produced uploads, skip further processing
      return i if i.respond_to?(:uploads) && i.uploads.present?

      self.class.probe i
      return i.stl.error "Unknown type for #{i.fn_in}" unless i.type

      generate_hashtags(i) if i.opts.hashtags

      if i.opts.genshorts
        Processors::Shorts.new(dir: dir, msg: msg, st: st, stline: i.stl).generate_and_upload_shorts(i)
        return i
      end

      stream = streamable?(i)
      warn_compromised_quality(i) unless stream || i.opts.onlysrt

      binding.pry if ENV['PRY_BEFORE_CONVERT']

      if i.opts.onlysrt
        generate_srt_only(i)
        return i
      end

      i.thumb = i.opts.thumb = Timeout.timeout(15) do
        Utils::Thumb.process(i.info, base_filename: i.info._filename, on_error: -> e { service.report_error(msg, e) })
      end rescue nil
      i.fn_out = stream ? passthrough(i, pos: pos) : convert(i, pos: pos)
      return if i.stl.error?

      if Zipper.size_mb_limit
        mbsize = ::File.size(i.fn_out) / 2**20
        return i.stl.error VID_TOO_BIG[] if i.type == Types.video and mbsize >= Zipper.size_mb_limit
        return i.stl.error TOO_BIG[] if mbsize >= Zipper.size_mb_limit
      end

      tag i

      i
    end

    def generate_srt_only i
      srt_path = Zipper.generate_srt(i.fn_in, dir: dir, info: i.info, probe: i.probe, stl: i.stl, opts: i.opts)
      i.fn_out = srt_path
      i.type   = SymMash.new(name: :document)
      i.mime   = 'application/x-subrip'
      i.opts.format = SymMash.new(mime: i.mime)
      i.uploads = nil
    end

    def generate_hashtags(i)
      subtitle = Subtitler.transcribe(i.fn_in, stl: @stl)
      @stl&.update 'generating hashtags'
      i.info.hashtags = Hashtags.generate(subtitle, lang: LanguageOpts.from(i.opts, subtitle.language))
    end

    def tag i
      Tagger.add_cover i.fn_out, i.thumb if i.thumb and i.type == Types.audio
    end

    # Only encoding squeezes the media to fit the limit; a streamed file was picked to fit it.
    def warn_compromised_quality(i)
      return unless Zipper.size_mb_limit

      i.stl.update VID_TOO_LONG[] if i.type == Types.video && i.durat > Zipper.vid_duration_thld.minutes.to_i
      i.stl.update AUD_TOO_LONG[] if i.type == Types.audio && i.durat > Zipper.aud_duration_thld.minutes.to_i
    end

    # The downloader already fetched a Telegram-playable file that fits the limit, so upload it untouched.
    def streamable?(i)
      format = STREAM_FORMATS[::File.extname(i.fn_in)]
      i.stream.present? && format && i.type.name == Utils::MimeTypes.type_for_mime(format.mime) && Streaming.fits?(i.fn_in)
    end

    def passthrough(i, pos: nil)
      i.format = STREAM_FORMATS.fetch(::File.extname(i.fn_in))
      i.mime   = i.format.mime
      ::File.expand_path(Output.filename(i.info, dir: dir, ext: i.format.ext, pos: pos)).tap { |fn_out| FileUtils.mv i.fn_in, fn_out }
    end

    def convert i, pos: nil
      i.stl.update 'transcoding'
      speed    = i.opts.speed&.to_f
      durat    = i.durat
      durat   /= speed if speed

      Presets::Camera.apply(i.opts, path: i.fn_in) if video_input?(i) && i.opts.camera

      chosen   = Zipper.choose_format i.type, i.opts, durat
      return i.stl.error 'Unsupported format' unless chosen

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
      fn_in = dub_video(i, fn_in) if dub_video?(i)

      o, e, st = Zipper.send "zip_#{i.type.name}", fn_in, fn_out,
        opts: i.opts, probe: i.probe, stl: i.stl, info: i.info
      return i.stl.error "convert failed: #{e.lines.last(3).join.strip}" unless st.success?

      fn_out
    end

    def video_input?(i)
      i.type == Types.video || i.type&.name&.to_sym == :video
    end

    def dub_video?(i)
      i.opts.dub && video_input?(i)
    end

    def dub_video(i, fn_in)
      Dubbing::Pipeline.apply(fn_in, dir: dir, opts: i.opts, stl: i.stl, probe: i.probe)
    end

  end
end
