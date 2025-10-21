require_relative 'base'

module Downloaders
  class YtDlp < Base
    Downloaders.register(self)
    def self.supports?(_processor)
      true
    end
    require 'http/cookie'
    require 'time'

    VL = 10
    AL = nil

    MAX_RES    = ENV['MAX_RES'] || 1080
    DOWN_BIN   = 'yt-dlp'
    DOWN_ARGS  = "-S 'res:#{MAX_RES}' --ignore-errors"
    DOWN_ARGS << ' --compat-options no-live-chat'
    DOWN_CMD   = "#{DOWN_BIN} #{DOWN_ARGS}".freeze
    USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36'
    DOWN_OPTS  = %i[referer]

    def download
      cmd  = base_cmd + " --write-info-json --no-clean-infojson --skip-download -o 'info-%(playlist_index)s.%(ext)s' '#{url}'"
      cmd << " --match-filter 'live_status != is_upcoming'" if url.match /youtu\.?be/
      cmd << ' --age-limit 18'
      cmd << " --extractor-args 'youtube:lang=#{opts.lang}'" if opts.lang

      o, e, st = Sh.run cmd, chdir: dir
      if st != 0
        processor.st.error "Metadata errors:\n<pre>#{MsgHelpers.he e}</pre>", parse_mode: 'HTML'
      end

      infos = Dir.glob("#{tmp}/*.info.json").sort_by { |f| File.mtime f }
      infos.map! do |infof|
        info = SymMash.new JSON.parse File.read infof
        File.unlink infof
        next unless info._filename
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
        short_url  = Utils::UrlShortener.shortify(info) || ourl

        info.title = info.track if info.track
        info.title = info.description || info.title if info.webpage_url.index 'instagram.com'
        info.title = format('%02d %s', i + 1, info.title) if mult && opts.number
        info.title = MsgHelpers.limit info.title, percent: 90

        cands = [Array(info.fragments).sum { |f| f.duration.to_f }, Array(info.formats).map { |f| [f.duration.to_f, Array(f.fragments).sum { |fr| fr.duration.to_f }].max }.max]
        info.duration ||= cands.compact.select { |d| d.to_f > 0 }.max&.to_i

        max_len = VID_MAX_LENGTH[]
        dur = (info.duration || 0).to_i
        if info.video_ext != 'none' && Zipper.size_mb_limit && !opts.onlysrt && !from_admin?(msg) &&
           dur.positive? && dur >= max_len.to_i
          return processor.st.error VID_MAX_NOTICE[]
        end

        SymMash.new(
          url:  short_url,
          opts: opts,
          info: info,
        )
      end
    end

    def download_one(i, pos: nil)
      pos ||= 1
      fn  = "input-#{pos}"
      cmd = base_cmd + " -o '#{fn}.%(ext)s' '#{i.url}'"
      _, e, st = Sh.run cmd, chdir: dir
      return processor.st.error "download error #{e}" unless st == 0

      fn_in = i.info._filename = i.fn_in = Dir.glob("#{tmp}/#{fn}.*").first
      return processor.st.error "can't find file #{fn_in}" unless File.exist? fn_in

      true
    end

    protected

    MIN_PER_MB     = 35.0 / 50
    VID_MAX_LENGTH = -> {
      return Float::INFINITY unless Zipper.size_mb_limit
      (MIN_PER_MB * Zipper.size_mb_limit).minutes
    }
    VID_MAX_NOTICE = -> {
      mx = (MIN_PER_MB * Zipper.size_mb_limit).round
      "Can't download files bigger than #{mx} minutes due to bot #{Zipper.size_mb_limit}MB restriction"
    }

    def base_cmd
      @base_cmd ||= begin
        bcmd  = DOWN_CMD.dup
        bcmd << " --paths #{tmp}"
        bcmd << " --cache-dir #{tmp}/cache"
        bcmd << ' -s' if opts.simulate
        bcmd << cookie_cli_args(url)

        videof  = 'bestvideo[ext=mp4]'
        audiof  = 'bestaudio[ext=mp4]'
        audiof  = 'mp3-320' if url.index 'bandcamp.com'

        if opts.ss || opts.to
          bcmd << ' --downloader ffmpeg'
          darr = []
          darr << "-ss #{opts.ss}" if opts.ss
          darr << "-to #{opts.to}" if opts.to
          bcmd << " --downloader-args \"ffmpeg_i:#{darr.join(' ')}\""
          opts.except! :ss, :to
          videof = audiof = nil
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

    def build_cookie_files_for(u)
      host = URI(u).host rescue nil
      return [nil, nil] if host.blank?

      ck = fetch_saved_cookie_for_host(host)
      return [nil, nil] if ck.to_s.strip.empty?

      jar = HTTP::CookieJar.new
      uri = URI.parse(u) rescue nil
      parse_cookie_entries(ck).each do |name, value, attrs|
        next if name.to_s.empty?
        dom   = attrs['domain']
        path  = attrs['path'].presence || '/'
        secure= !!attrs['secure']
        exp   = parse_cookie_expires(attrs['expires'] || attrs['expirationDate'])
        cookie = dom.present? ? HTTP::Cookie.new(name, value, domain: dom, for_domain: dom.start_with?('.'), path: path, secure: secure, expires: exp)
                               : HTTP::Cookie.new(name, value, origin: uri, path: path, secure: secure, expires: exp)
        jar.add(cookie)
      end

      return [nil, nil] if jar.empty?
      in_path  = File.join(tmp, 'cookies.in.txt')
      jar.save(in_path, format: :cookiestxt)
      [in_path, File.join(tmp, 'cookies.jar.txt')]
    end

    def parse_cookie_entries(ck)
      s = ck.to_s.strip
      return [] if s.empty?
      return (JSON.parse(s) rescue []).map { |c| [c['name'], c['value'], c] } if s.start_with?('[')
      s.split(/;\s*/).filter_map { |p| n, v = p.split('=', 2); n.present? ? [n, v, {}] : nil }
    end

    def parse_cookie_expires(exp)
      return nil unless exp
      exp.is_a?(String) ? Time.parse(exp) : Time.at(exp.to_f)
    rescue StandardError
      nil
    end

    def fetch_saved_cookie_for_host(host)
      return nil unless defined?(Models::Session)
      s = Models::Session[uid: msg.from.id] rescue nil
      return nil unless s && s.cookies.is_a?(Hash)
      domains = []
      parts = host.to_s.split('.')
      (0..[parts.size - 2, 0].max).each { |i| domains << parts[i..-1].join('.') }
      domains.find_map { |d| s.cookies[d] }
    end

    def cookie_cli_args(u)
      cfile, cjar = build_cookie_files_for(u)
      return '' unless cfile
      " --cookies '#{cfile}' --cookie-jar '#{cjar}'"
    rescue StandardError => e
      st.error "Cookie error: #{MsgHelpers.he e.message}"
    end
  end
end


