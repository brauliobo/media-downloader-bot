require_relative 'base'
require_relative '../utils/cookie_jar'
require_relative '../prober'
require 'fileutils'

module Downloaders
  class YtDlp < Base
    Downloaders.register(self)
    def self.supports?(_ctx); true; end

    MAX_RES  = ENV['MAX_RES'] || 1080
    BASE_CMD = "yt-dlp -S 'res:#{MAX_RES}' --ignore-errors --compat-options no-live-chat".freeze
    REMOTE   = ENV['YT_DLP_REMOTE_COMPONENTS']

    def download
      cmd = "#{base_cmd} --write-info-json --no-clean-infojson --skip-download -o #{Sh.escape("info-%(playlist_index)s.%(ext)s")} #{Sh.escape(url)}"
      cmd << " --match-filter #{Sh.escape('live_status != is_upcoming')}" if url.match?(/youtu\.?be/)
      
      _, e, s = Sh.run cmd, chdir: dir
      return st.error("Metadata errors:\n<pre>#{Bot::MsgHelpers.he e}</pre>", parse_mode: 'HTML') unless s == 0

      process_infos
    end

    def download_one(i, pos: 1)
      fn = "input-#{pos}"
      cmd = "#{base_cmd} -o #{Sh.escape("#{fn}.%(ext)s")} #{Sh.escape(i.url)}"
      _, e, s = Sh.run cmd, chdir: dir
      return st.error("download error #{e}") unless s == 0

      files = Dir["#{tmp}/#{fn}.*"].reject { |f| f.end_with?('.part') }.sort
      want_video = !(opts.onlysrt || opts.audio)
      i.fn_in = pick_downloaded_file(files, want_video: want_video)
      
      return st.error(want_video ? "can't find video stream" : "can't find file") unless i.fn_in && File.exist?(i.fn_in)

      # --download-sections already cut the file; timestamps start at 0.
      # Clear ss/to so the zipper doesn't double-cut or miscalculate duration.
      opts.ss = nil if opts.ss
      opts.to = nil if opts.to
      true
    end

    private

    def pick_downloaded_file(files, want_video:)
      files = Array(files).select { |f| f && File.exist?(f) }
      return nil if files.empty?
      return files.first unless want_video

      files.each do |f|
        probe = Prober.for(f) rescue nil
        next unless probe&.streams
        return f if probe.streams.any? { |s| s.codec_type == 'video' }
      end

      nil
    end

    def base_cmd
      @base_cmd ||= begin
        cmd = [BASE_CMD]
        cmd << "--remote-components #{Sh.escape(REMOTE)}" unless REMOTE.to_s.strip.empty?
        cmd << "--paths #{tmp}"
        cmd << '-s' if opts.simulate

        if opts.alang && url.match?(/youtu\.?be/)
          cmd << "--extractor-args #{Sh.escape("youtube:lang=#{opts.alang}")}"
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

        # Format selection
        is_audio = opts.onlysrt || opts.audio
        bandcamp = url.include?('bandcamp.com')
        al = opts.alang
        if is_audio
          audiof = bandcamp ? 'mp3-320' : (al ? "bestaudio[language^=#{al}]/bestaudio/best" : 'bestaudio/best')
          cmd << "-f #{Sh.escape(audiof)}"
        elsif url.match?(/youtu\.?be/)
          cmd << "-f #{Sh.escape(al ? "best[ext=mp4][language^=#{al}]/best[ext=mp4]/best" : 'best[ext=mp4]/best')}"
        else
          cmd << "-f #{Sh.escape(al ? "bestvideo+bestaudio[language^=#{al}]/bestvideo+bestaudio/best" : 'bestvideo+bestaudio/best')}"
          cmd << "--merge-output-format mp4"
        end

        # Playlist/Limit logic
        ml = opts.audio ? nil : 10
        
        if opts.after
          opts.limit ||= ml
        end

        if ml && opts.limit && opts.limit.to_i > ml && !Bot::MsgHelpers.from_admin?(msg)
          opts.limit = ml
        end

        if opts.limit.to_i.positive?
          cmd << "--playlist-end #{opts.limit.to_i}"
        end

        cmd << '-x' if opts.audio || opts.onlysrt
        
        %i[referer].each { |k| cmd << "--#{k} #{Sh.escape(opts[k])}" if opts[k] }
        
        cmd.join(' ')
      end
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

      SymMash.new(url: short_url, opts: opts, info: info)
    end

    def format_title(info, i, mult)
      t = info.track || info.title
      t = info.description || t if info.webpage_url.include?('instagram.com')
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
      
      return unless Zipper.size_mb_limit && !opts.onlysrt && !Bot::MsgHelpers.from_admin?(msg)
      
      max_min = (35.0 / 50 * Zipper.size_mb_limit)
      if info.video_ext != 'none' && info.duration.to_i >= max_min.minutes
        st.error "Can't download files bigger than #{max_min.round} minutes"
      end
    end
  end
end
