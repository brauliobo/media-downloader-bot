require_relative '../downloader'

class Manager
  class YtDlp < ::Downloader

    # max number of videos and audios for non-admins to download
    VL = 10
    AL = nil

    MAX_RES    = ENV['MAX_RES'] || 1080
    DOWN_BIN   = 'yt-dlp'
    DOWN_ARGS  = "-S 'res:#{MAX_RES}' --ignore-errors"
    DOWN_ARGS << ' --compat-options no-live-chat'
    DOWN_CMD   = "#{DOWN_BIN} #{DOWN_ARGS}".freeze
    USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36'
    DOWN_OPTS  = %i[referer]

    # Approximate minutes allowed per megabyte based on original 35-min @ 50 MB limit.
    MIN_PER_MB     = 35.0 / 50
    VID_MAX_LENGTH = -> {
      return Float::INFINITY unless Zipper.size_mb_limit
      (MIN_PER_MB * Zipper.size_mb_limit).minutes
    }
    VID_MAX_NOTICE = -> {
      mx = (MIN_PER_MB * Zipper.size_mb_limit).round
      "Can't download files bigger than #{mx} minutes due to bot #{Zipper.size_mb_limit}MB restriction"
    }

    # ------------------------------------------------------------------
    def download
      cmd  = base_cmd + " --write-info-json --no-clean-infojson --skip-download -o 'info-%(playlist_index)s.%(ext)s' '#{url}'"
      cmd << " --match-filter 'live_status != is_upcoming'" if url.match /youtu\.?be/
      cmd << ' --age-limit 18'
      cmd << " --extractor-args 'youtube:lang=#{opts.lang}'" if opts.lang # title language

      o, e, st = Sh.run cmd, chdir: dir
      if st != 0
        processor.st.error "Metadata errors:\n<pre>#{MsgHelpers.he e}</pre>", parse_mode: 'HTML'
        # Continue with the inputs available
      end

      infos = Dir.glob("#{tmp}/*.info.json").sort_by { |f| File.mtime f }
      infos.map! do |infof|
        info = SymMash.new JSON.parse File.read infof
        File.unlink infof # for the next Dir.glob to work properly
        next unless info._filename # skip playlist-level metadata
        info
      end.compact!

      if opts.after
        ai = infos.index { |i| i.display_id == opts.after }
        return processor.st.error 'Can\'t find after id' unless ai
        infos = infos[0..(ai - 1)]
      end

      mult = infos.size > 1
      infos.map.with_index do |info, i|
        ourl       = info.url = mult ? info.webpage_url : url
        short_url  = Manager::UrlShortner.shortify(info) || ourl

        info.title = info.track if info.track # e.g. bandcamp
        info.title = info.description || info.title if info.webpage_url.index 'instagram.com'
        info.title = format('%02d %s', i + 1, info.title) if mult && opts.number
        info.title = MsgHelpers.limit info.title, percent: 90

        max_len = VID_MAX_LENGTH[]
        if info.video_ext != 'none' && Zipper.size_mb_limit && !opts.onlysrt && !from_admin?(msg) &&
           info.duration >= max_len.to_i
          return processor.st.error VID_MAX_NOTICE[]
        end

        SymMash.new(
          url:  short_url,
          opts: opts,
          info: info,
        )
      end
    end

    # Downloads a single item from a playlist (called by Worker).
    def download_one(i, pos: nil)
      fn  = "input-#{pos}"
      cmd = base_cmd + " -o '#{fn}.%(ext)s' '#{i.url}'"
      _, e, st = Sh.run cmd, chdir: dir
      return processor.st.error "download error #{e}" unless st == 0

      fn_in = i.info._filename = i.fn_in = Dir.glob("#{tmp}/#{fn}.*").first
      return processor.st.error "can't find file #{fn_in}" unless File.exist? fn_in

      true
    end

    protected

    def base_cmd
      @base_cmd ||= begin
        bcmd  = DOWN_CMD.dup
        bcmd << " --paths #{tmp}"
        bcmd << " --cache-dir #{tmp}/cache"
        bcmd << ' -s' if opts.simulate

        videof  = 'bestvideo[ext=mp4]'
        audiof  = 'bestaudio[ext=mp4]'
        # FIXME: retuning invalid format
        #audiof << "[language=#{opts.lang}]" if opts.lang
        audiof  = 'mp3-320' if url.index 'bandcamp.com' # FIXME: it is choosing flac

        # Inject ffmpeg downloader cut when start/stop times are given
        if opts.ss || opts.to
          bcmd << ' --downloader ffmpeg'
          darr = []
          darr << "-ss #{opts.ss}" if opts.ss
          darr << "-to #{opts.to}" if opts.to
          bcmd << " --downloader-args \"ffmpeg_i:#{darr.join(' ')}\""
          opts.except! :ss, :to # skip doing it on Zipper
          videof = audiof = nil # format selection not compatible
        end

        bcmd << " -f '#{videof}+#{audiof}/best'" if videof && audiof

        ml = opts.audio ? AL : VL
        opts.limit ||= ml if opts.after
        opts.limit   = ml if ml && opts.limit && opts.limit.to_i > ml && !from_admin?(msg)
        bcmd << " --playlist-end #{opts.limit.to_i}" if opts.limit.to_i.positive?

        bcmd << ' -x' if opts.audio

        opts.slice(*DOWN_OPTS).each do |k, v|
          v.gsub! "'", "\\'"
          bcmd << " --#{k} '#{v}'"
        end

        bcmd
      end
    end
  end
end
