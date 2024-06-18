class Bot
  class UrlProcessor < Processor

    # max number of videos and audios for non-admins to download
    VL = 10
    AL = nil

    MAX_RES    = 1080
    DOWN_BIN   = "yt-dlp"
    DOWN_ARGS  = "-S 'res:#{MAX_RES}' --ignore-errors"
    DOWN_ARGS << " --compat-options no-live-chat"
    DOWN_CMD   = "#{DOWN_BIN} #{DOWN_ARGS}".freeze
    USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36'
    DOWN_OPTS  = %i[referer]

    def self.add_opt h, o
      k,v = o.split '=', 2
      h[k] = v || 1
    end

    def download
      cmd  = base_cmd + " --write-info-json --no-clean-infojson --skip-download -o 'info-%(playlist_index)s.%(ext)s' '#{url}'"
      cmd << " --match-filter 'live_status != is_upcoming'" if url.match /youtu\.?be/
      cmd << " --age-limit 18"
      cmd << " --extractor-args 'youtube:lang=#{opts.lang}'" if opts.lang

      o, e, st = Sh.run cmd, chdir: dir
      if st != 0
        @st.error "Metadata errors:\n<pre>#{he e}</pre>", parse_mode: 'HTML'
        # continue with inputs available
      end

      infos = Dir.glob("#{tmp}/*.info.json").sort_by{ |f| File.mtime f }
      infos.map! do |infof|
        info = SymMash.new JSON.parse File.read infof
        File.unlink infof # for the next Dir.glob to work properly

        next unless info._filename # playlist info
        info
      end.compact!

      if opts.after
        ai = infos.index{ |i| i.display_id == opts.after }
        return @st.error "Can't find after id" unless ai
        infos = infos[0..(ai-1)]
      end

      mult = infos.size > 1
      infos.map.with_index do |info, i|
        ourl = info.url = if mult then info.webpage_url else self.url end
        url  = Bot::UrlShortner.shortify(info) || ourl

        info.title = info.track if info.track # e.g. bandcamp
        info.title = info.description || info.title if info.webpage_url.index 'instagram.com'
        info.title = "#{"%02d" % (i+1)} #{info.title}" if mult and opts.number
        info.title = Bot::Helpers.limit info.title, percent: 90

        SymMash.new(
          url:  url,
          opts: opts,
          info: info,
        )
      end
    end

    def download_one i, pos: nil
      fn = "input-#{pos}"
      st = nil
      cmd = base_cmd + " -o '#{fn}.%(ext)s' '#{i.url}'"
      o, e, st = Sh.run cmd, chdir: dir
      return @st.error "#{i.info.title}: download error #{e}" unless st == 0

      fn_in = i.info._filename = i.fn_in = Dir.glob("#{tmp}/#{fn}.*").first

      return @st.error "#{info.title}: can't find file #{fn_in}" unless File.exist? fn_in

      true
    end

    protected

    def base_cmd
      @base_cmd ||= self.then do
        bcmd  = DOWN_CMD.dup
        bcmd << " --embed-subs"
        bcmd << " --paths #{tmp}"
        bcmd << " --cache-dir #{tmp}/cache"
        bcmd << ' -s' if opts.simulate

        ml = if opts.audio then AL else VL end
        opts.limit ||= ml if opts.after
        opts.limit   = ml if ml and opts.limit and opts.limit.to_i > ml and !from_admin?(msg)
        bcmd << " --playlist-end #{opts.limit.to_i}" if opts.limit.to_i > 0

        bcmd << ' -x' if opts.audio
        bcmd << ' -f mp3-320/best' if url.index 'bandcamp.com' # FIXME: it is choosing flac

        opts.slice(*DOWN_OPTS).each do |k,v|
          v.gsub! "'", "\'"
          bcmd << " --#{k} '#{v}'"
        end

        #bcmd << " --cookies #{opts.cookie}" if opts.cookie
        #bcmd << " --cookies-from-browser #{opts.cookie}" if opts.cookie and from_admin? msg # FIXME: depends on unit user
        # user-agent can slowdown on youtube
        #bcmd << " --user-agent '#{USER_AGENT}'" unless uri.host.index 'facebook'

        bcmd
      end
    end

  end
end
