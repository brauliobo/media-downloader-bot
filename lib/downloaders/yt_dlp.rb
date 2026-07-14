require_relative 'base'
require_relative '../utils/cookie_jar'
require_relative '../utils/http'
require_relative '../prober'
require 'fileutils'
require 'uri'

module Downloaders
  class YtDlp < Base
    Downloaders.register(self)
    def self.supports?(_ctx); true; end

    MAX_RES  = ENV['MAX_RES'] || 1080
    BASE_CMD = "yt-dlp -S 'res:#{MAX_RES}' --ignore-errors --compat-options no-live-chat".freeze
    REMOTE   = ENV['YT_DLP_REMOTE_COMPONENTS']

    def download
      source_url = url.to_s
      return st.error('No URL found') if source_url.blank?
      source_url = normalize_url(source_url)

      cmd = "#{base_cmd} --write-info-json --no-clean-infojson --skip-download -o #{Sh.escape("info-%(playlist_index)s.%(ext)s")} #{Sh.escape(source_url)}"
      cmd << " --match-filter #{Sh.escape('live_status != is_upcoming')}" if source_url.match?(/youtu\.?be/)
      
      _, e, s = Sh.run cmd, chdir: dir
      return st.error("Metadata errors:\n<pre>#{Bot::MsgHelpers.he e}</pre>", parse_mode: 'HTML') unless s == 0

      process_infos
    end

    def download_one(i, pos: 1)
      fn  = "input-#{pos}"
      url = i.info&.webpage_url.presence || i.url
      url = "https://#{url}" unless url =~ /\Ahttps?:\/\//i
      url = normalize_url(url)
      cmd = "#{base_cmd} -o #{Sh.escape("#{fn}.%(ext)s")} #{Sh.escape(url)}"
      _, e, s = Sh.run cmd, chdir: dir
      raise "download error: #{e}" unless s == 0

      files = Dir["#{tmp}/#{fn}.*"].reject { |f| f.end_with?('.part') }.sort
      want_video = !(opts.onlysrt || opts.audio)
      i.fn_in = pick_downloaded_file(files, want_video: want_video)

      raise(want_video ? "can't find video stream" : "can't find file") unless i.fn_in && File.exist?(i.fn_in)

      # --download-sections already cut the file; timestamps start at 0.
      # Clear ss/to so the zipper doesn't double-cut or miscalculate duration.
      opts.ss = nil if opts.ss
      opts.to = nil if opts.to
      i.opts.ss = nil if i.opts.ss
      i.opts.to = nil if i.opts.to
      true
    end

    private

    def format_selector
      return 'mp3-320' if opts.audio && url.include?('bandcamp.com')
      base = (opts.onlysrt || opts.audio) ? 'bestaudio' : 'bestvideo+bestaudio'
      al = opts.alang
      return "#{base}/best" unless al
      "#{base}[language^=#{al}]/best[language^=#{al}]/#{base}/best"
    end

    def pick_downloaded_file(files, want_video:)
      files   = Array(files).select { |f| f && File.exist?(f) }
      desired = want_video ? 'video' : 'audio'
      errors  = []
      probed  = false

      found = files.find do |f|
        probe = Prober.for(f)
        probed = true
        probe&.streams&.any? { |s| s.codec_type == desired }
      rescue StandardError => e
        errors << "#{File.basename(f)}: #{e.message}"
        false
      end

      raise Sh::Error.new('probe failed', errors.join(', ')) if errors.present? && !probed

      found
    end

    def admin?
      msg && Bot::MsgHelpers.from_admin?(msg)
    end

    def base_cmd
      @base_cmd ||= begin
        cmd = [BASE_CMD]
        cmd << "--remote-components #{Sh.escape(REMOTE)}" unless REMOTE.to_s.strip.empty?
        cmd << "--paths #{tmp}"
        cmd << '-s' if opts.simulate
        cmd << "--extractor-args #{Sh.escape('generic:impersonate')}"

        if opts.alang && url.match?(/youtu\.?be/)
          args = "youtube:lang=#{opts.alang};player_client=web_embedded,default"
          cmd << "--extractor-args #{Sh.escape(args)}"
        end
        
        begin
          if (cp = Utils::CookieJar.write(session, tmp))
            cmd << "--cookies #{Sh.escape(cp)}"
          end
        rescue StandardError => e
          st.error "Cookie error: #{e.class}: #{e.message}"
        end

        # Download only the requested section (cuts during download, saves bandwidth)
        if opts.ss || opts.to
          from = opts.ss || '0'
          to   = opts.to || 'inf'
          cmd << "--download-sections #{Sh.escape("*#{from}-#{to}")}"
        end

        cmd << "-f #{Sh.escape(format_selector)}"

        apply_playlist_options(cmd)

        cmd << '-x' if opts.audio || opts.onlysrt
        
        %i[referer].each { |k| cmd << "--#{k} #{Sh.escape(opts[k])}" if opts[k] }
        
        cmd.join(' ')
      end
    end

    def normalize_url(source_url)
      uri = URI(source_url)
      host = uri.host.to_s.downcase
      return source_url unless host == 'rumble.com' || host.end_with?('.rumble.com')
      return source_url if uri.path.match?(%r{\A/embed/}i)

      clean_url = uri.dup.tap { |u| u.query = u.fragment = nil }.to_s
      body      = Utils::HTTP.get("https://rumble.com/api/Media/oembed.json?#{URI.encode_www_form(url: clean_url)}").body
      JSON.parse(body)['html'].to_s[%r{https://rumble\.com/embed/[^"']+}] || source_url
    rescue StandardError
      source_url
    end

    def apply_playlist_options(cmd)
      return cmd << '--no-playlist' if opts.ss || opts.to
      return cmd << '--no-playlist' unless admin?

      opts.limit ||= (opts.audio ? nil : 10) if opts.after
      cmd << "--playlist-end #{opts.limit.to_i}" if opts.limit.to_i.positive?
    end

    def process_infos
      infos = Dir["#{tmp}/*.info.json"].sort_by { |f| File.mtime(f) }
      infos = infos.map { |f| load_info(f) }.compact
      
      if opts.after && (idx = infos.index { |i| i.display_id == opts.after })
        infos = infos[0...idx]
      elsif opts.after
        return st.error "Can't find after id"
      end

      mult = infos.size > 1
      infos.map.with_index { |info, i| build_input(info, i, mult) }
    end

    def load_info(file)
      json = JSON.parse(File.read(file))
      File.unlink(file)
      SymMash.new(json) if json['_filename']
    end

    def build_input(info, i, mult)
      info.url   = mult ? info.webpage_url : url
      short_url  = Utils::UrlShortener.shortify(info) || info.url
      info.title = format_title(info, i, mult)
      
      err = check_duration!(info)
      return err if err 

      SymMash.new(url: short_url, opts: opts.deep_dup, info: info)
    end

    def format_title(info, i, mult)
      t = info.track || info.title
      t = info.description || t if info.webpage_url.include?('instagram.com')
      if info.description && info.webpage_url.to_s.match?(%r{(?:^|://)(?:[^/]+\.)?(?:x|twitter)\.com/.+/status/}) && t.to_s.strip.end_with?('...')
        t = info.description
      end
      t = format('%02d %s', i + 1, t) if mult && opts.number
      t
    end

    def check_duration!(info)
      # Calculate duration from fragments if needed
      unless info.duration
        durs = [Array(info.fragments).sum { |f| f.duration.to_f }]
        durs << Array(info.formats).map { |f| [f.duration.to_f, Array(f.fragments).sum { |fr| fr.duration.to_f }].max }.max
        info.duration = durs.compact.max&.to_i
      end
      
      return unless Zipper.size_mb_limit && !opts.onlysrt && !admin?
      
      max_min = (35.0 / 50 * Zipper.size_mb_limit)
      if info.video_ext != 'none' && info.duration.to_i >= max_min.minutes
        st.error "Can't download files bigger than #{max_min.round} minutes"
      end
    end
  end
end
