require 'chronic_duration'
require_relative '../output'
require_relative '../shorts'

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

      if i.opts.genshorts
        generate_and_upload_shorts(i)
        return i
      end

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

    def generate_and_upload_shorts(i)
      @stl&.update 'generating shorts plan'
      srt = nil
      if i.opts.genshorts.is_a?(String) && File.exist?(i.opts.genshorts)
        srt = File.read(i.opts.genshorts)
      else
        srt_path = Zipper.generate_srt(i.fn_in, dir: dir, info: i.info, probe: i.probe, stl: @stl, opts: i.opts)
        srt = File.read srt_path
      end
      sub_lang = i.info.respond_to?(:language) ? i.info.language : nil
      lang = i.opts.lang || sub_lang
      cuts = begin
        Shorts.generate_cuts_from_srt(srt, language: lang)
      rescue => e
        @stl&.update "ollama failed: #{e.message}"; []
      end

      if cuts.blank?
        # Fallback: naive segmentation every ~60s
        total = (i.durat || i.probe.format.duration.to_i).to_i
        step  = 60
        t = 0
        cuts = []
        while t < total
          s = t; e = [t + step, total].min
          cuts << { start: Time.at(s).utc.strftime('%H:%M:%S'), end: Time.at(e).utc.strftime('%H:%M:%S') }
          t += step
        end
        # Try to get titles for fallback segments
        begin
          titles = Shorts.generate_titles_for_segments(srt, cuts, language: lang)
          cuts.each_with_index { |c, idx| c[:title] = titles[idx].presence || "Short #{idx+1}" }
        rescue => e
          # As a last resort, derive from sliced VTT to avoid generic numbering
          begin
            vtt_src = srt.include?('WEBVTT') ? srt : Zipper::Subtitle.srt_text_to_vtt(srt)
          rescue; vtt_src = nil; end
          cuts.each_with_index do |c, idx|
            guess = vtt_src ? Shorts.title_from_vtt(Zipper::Subtitle.slice_vtt(vtt_src, from: c[:start], to: c[:end])) : nil
            c[:title] = (guess.presence || "Short #{idx+1}")
          end
          @stl&.update "fallback titles used (#{e.message})"
        end
        @stl&.update "fallback plan generated: #{cuts.size} cuts"
      else
        @stl&.update "cuts planned: #{cuts.size}"
      end

      uploads = []
      cuts.each_with_index do |c, idx|
        fn_out = Output.filename(i.info, dir: dir, ext: i.format&.ext || 'mp4', pos: idx+1)
        locopts = SymMash.new(i.opts.deep_dup)
        locopts[:ss] = c[:start]
        locopts[:to] = c[:end]
        locopts[:subs] = nil
        locopts[:onlysrt] = nil
        locopts[:genshorts] = nil
        locopts[:caption] = 1
        # Generate per-cut VTT slice from original VTT when available
        begin
          if srt && srt.include?('-->')
            vtt_src = srt.include?('WEBVTT') ? srt : Zipper::Subtitle.srt_text_to_vtt(srt)
          end
        rescue; vtt_src = nil; end
        if vtt_src
          slice_vtt = Zipper::Subtitle.slice_vtt(vtt_src, from: c[:start], to: c[:end])
          locopts[:sub_vtt] = slice_vtt
          locopts[:sub_lang] = lang if lang
          locopts[:_sub_prefix] = "sub_#{idx+1}"
          (i.opts._vtt_slices ||= [])[idx] = slice_vtt
        end
        s_dur = (hms_to_seconds(c[:end]) || 0) - (hms_to_seconds(c[:start]) || 0)
        s_dur = 60 if s_dur <= 0
        chosen = Zipper.choose_format(Zipper::Types.video, locopts, s_dur)
        locopts.format = chosen || Zipper::Types.video.h264

        Dir.chdir dir do
          o, e, st = Zipper.zip_video(i.fn_in, fn_out, opts: locopts, probe: i.probe, stl: @stl, info: i.info)
          next @stl&.error("convert failed: #{o}\n#{e}") if st != 0
        end

        uploads << SymMash.new(path: fn_out, caption: c[:title].to_s.strip.presence || i.info.title)
      end

      @stl&.update "cutting done: #{uploads.size} files"
      # After cutting, ensure titles are AI-generated based on per-slice subtitles
      begin
        if i.opts._vtt_slices&.any?
          titles = Shorts.generate_titles_for_segments(srt, cuts, language: lang, vtt_slices: i.opts._vtt_slices)
          uploads.each_with_index { |up, j| up.caption = titles[j].presence || up.caption }
        end
      rescue => e
        @stl&.update "title regen failed: #{e.message}"
      end
      i.uploads = uploads
    end

    def hms_to_seconds(str)
      s = str.to_s.strip
      if s =~ /\A(\d{1,2}):(\d{2}):(\d{2})\z/
        $1.to_i * 3600 + $2.to_i * 60 + $3.to_i
      else
        ChronicDuration.parse(s) rescue nil
      end
    end

  end
end
