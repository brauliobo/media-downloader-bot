class Bot
  class UrlProcessor < Processor

    attr_reader :args
    attr_reader :uri, :url
    attr_reader :opts

    MAX_RES    = 1080
    DOWN_BIN   = "yt-dlp"
    DOWN_ARGS  = "-S 'res:#{MAX_RES}' --ignore-errors"
    DOWN_ARGS << " --compat-options no-live-chat --match-filter 'live_status != is_upcoming'"
    DOWN_CMD   = "#{DOWN_BIN} #{DOWN_ARGS}".freeze
    USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36'
    DOWN_OPTS  = %i[referer]

    def self.add_opt h, o
      k,v = o.split '=', 2
      h[k] = v || 1
    end

    def initialize dir, line, bot, msg=nil
      super dir, bot, msg

      @line = line
      @args = line.split(/\s+/)
      @uri  = URI.parse @args.shift
      @url  = uri.to_s
      @opts = @args.each.with_object SymMash.new do |a, h|
        self.class.add_opt h, a
      end
    end

    def download
      cmd  = base_cmd + " --write-info-json --no-clean-infojson --skip-download -o 'info-%(playlist_index)s.%(ext)s' '#{url}'"
      o, e, st = Sh.run cmd, chdir: dir
      if st != 0
        edit_message msg, msg.resp.message_id, text: "Metadata errors:\n<pre>#{he e}</pre>", parse_mode: 'HTML'
        admin_report msg, e, status: 'Metadata errors'
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
        return report_error msg, "Can't find after id", context: i.inspect unless ai
        infos = infos[0..(ai-1)]
      end

      mult = infos.size > 1

      l = []
      infos.each.with_index.api_peach do |info, i|
        ourl = info.url = if mult then info.webpage_url else self.url end
        url  = Bot::UrlShortner.shortify(info) || ourl

        fn  = "input-#{i}"
        cmd = base_cmd + " -o '#{fn}.%(ext)s' '#{ourl}'"
        o, e, st = Sh.run cmd, chdir: dir
        next unless st == 0

        info.title = info.track if info.track # e.g. bandcamp
        info.title = info.description || info.title if info.webpage_url.index 'instagram.com'
        info.title = "#{"%02d" % (i+1)} #{info.title}" if mult and opts.number
        info.title = Bot::Helpers.limit info.title, percent: 90

        info._filename = fn_in = Dir.glob("#{tmp}/#{fn}.*").first

        next report_error msg, "Can't find file #{fn_in}", context: fn_in unless File.exist? fn_in

        i = input_from_file(fn_in, opts).merge url: url, info: info
        l << i
      end
      l
    end

    protected

    def base_cmd
      @base_cmd ||= self.then do
        bcmd  = DOWN_CMD.dup
        bcmd << " --embed-subs"
        bcmd << " --paths #{tmp}"
        bcmd << " --cache-dir #{tmp}/cache"
        bcmd << ' -s' if opts.simulate

        opts.limit ||= 50 if opts.after
        opts.limit   = 50 if opts.limit and opts.limit.to_i > 50 and !from_admin?(msg)
        bcmd << " --playlist-end #{opts.limit.to_i}" if opts.limit

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
