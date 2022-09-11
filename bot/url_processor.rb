class Bot
  class UrlProcessor < Processor

    attr_reader :args
    attr_reader :url
    attr_reader :opts

    DOWN_BIN   = "yt-dlp"
    DOWN_CMD   = "#{DOWN_BIN} --write-info-json --no-clean-infojson '%{url}'"
    USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36'
    DOWN_OPTS  = %i[referer]

    def initialize bot, msg, dir, line
      super bot, msg, dir

      @line = line
      @args = line.split(/\s+/)
      @url  = URI.parse @args.shift
      @opts = @args.each.with_object SymMash.new do |a, h|
        k,v = a.split '=', 2
        h[k] = v || 1
      end
    end

    def download 
      cmd  = DOWN_CMD % {url: url.to_s}
      cmd << " --cache-dir #{dir}"
      cmd << " -o 'input-%(playlist_index)s.%(ext)s'"
      cmd << ' -x' if opts.audio
      cmd << ' -s' if opts.simulate
      cmd << " --playlist-end #{opts.limit.to_i}" if opts.limit
      #cmd << " --cookies #{opts.cookie}" if opts.cookie 
      #cmd << " --cookies-from-browser #{opts.cookie}" if opts.cookie and from_admin? msg # FIXME: depends on unit user
      opts.slice(*DOWN_OPTS).each do |k,v|
        v.gsub! "'", "\'"
        cmd << " --#{k} '#{v}'"
      end
      # user-agent can slowdown on youtube
      #cmd << " --user-agent '#{USER_AGENT}'" unless url.host.index 'facebook'

      o, e, st = Open3.capture3 cmd, chdir: dir
      if st != 0
        edit_message msg, resp.result.message_id, text: "Download failed:\n<pre>#{he e}</pre>", parse_mode: 'HTML'
        admin_report msg, e, status: 'Download failed'
        return
      end

      infos  = Dir.glob("#{dir}/*.info.json").sort_by{ |f| File.mtime f }
      infos.map! do |infof|
        info = SymMash.new JSON.parse File.read infof
        File.unlink infof # for the next Dir.glob to work properly

        next unless info._filename # playlist info
        info
      end.compact!
      mult   = infos.size > 1

      infos.map.with_index do |info, i|
        fn    = info._filename
        # info._filename extension isn't accurate
        fn_in = Dir.glob("#{dir}/#{File.basename fn, File.extname(fn)}*").first

        # number files
        info.title = "#{"%02d" % (i+1)} #{info.title}" if mult and opts.number

        url = info.url = if mult then info.webpage_url else url.to_s end
        url = Bot::UrlShortner.shortify(info) || url
        SymMash.new(
          fn_in: fn_in,
          url:   url,
          info:  info,
          opts:  opts,
        )
      end.compact
    end

  end
end
