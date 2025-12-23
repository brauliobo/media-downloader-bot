require_relative 'base'
require_relative '../utils/cookie_jar'
require 'fileutils'

module Downloaders
  class YtDlp < Base
    Downloaders.register(self)
    def self.supports?(_ctx); true; end

    MAX_RES  = ENV['MAX_RES'] || 1080
    BASE_CMD = "yt-dlp -S 'res:#{MAX_RES}' --ignore-errors --compat-options no-live-chat".freeze
    REMOTE   = ENV['YT_DLP_REMOTE_COMPONENTS']

    def download
      cmd = "#{base_cmd} --write-info-json --no-clean-infojson --skip-download -o 'info-%(playlist_index)s.%(ext)s' '#{url}'"
      cmd << " --match-filter 'live_status != is_upcoming'" if url.match?(/youtu\.?be/)
      cmd << " --extractor-args 'youtube:lang=#{opts.lang}'" if opts.lang
      
      _, e, s = Sh.run cmd, chdir: dir
      return st.error("Metadata errors:\n<pre>#{Bot::MsgHelpers.he e}</pre>", parse_mode: 'HTML') unless s == 0

      process_infos
    end

    def download_one(i, pos: 1)
      fn = "input-#{pos}"
      cmd = "#{base_cmd} -o '#{fn}.%(ext)s' '#{i.url}'"
      _, e, s = Sh.run cmd, chdir: dir
      return st.error("download error #{e}") unless s == 0

      # Fix for regression: ensure we pick the video file if multiple files exist (e.g. split audio/video)
      files = Dir["#{tmp}/#{fn}.*"]
      i.fn_in = files.find { |f| f.match?(/\.(mp4|mkv|webm)$/i) } || files.first
      
      return st.error("can't find file") unless i.fn_in && File.exist?(i.fn_in)
      true
    end

    private

    def base_cmd
      @base_cmd ||= begin
        cmd = [BASE_CMD]
        cmd << "--remote-components #{REMOTE}" unless REMOTE.to_s.strip.empty?
        cmd << "--paths #{tmp} --cache-dir #{tmp}/cache"
        cmd << '-s' if opts.simulate
        
        begin
          if (cp = Utils::CookieJar.write(session, tmp))
            cmd << "--cookies '#{cp}'"
          end
        rescue StandardError => e
          st.error "Cookie error: #{e.class}: #{e.message}"
        end

        # FFmpeg args (cuts)
        if opts.ss || opts.to
          cmd << '--downloader ffmpeg'
          args = []
          args << "-ss #{opts.ss}" if opts.ss
          args << "-to #{opts.to}" if opts.to
          cmd << "--downloader-args \"ffmpeg_i:#{args.join(' ')}\""
        else
          # Format selection
          is_audio = opts.onlysrt || opts.audio
          bandcamp = url.include?('bandcamp.com')
          videof = is_audio ? nil : 'bestvideo[ext=mp4]'
          audiof = bandcamp ? 'mp3-320' : (is_audio ? 'bestaudio/best' : 'bestaudio[ext=mp4]')

          cmd << (videof ? "-f '#{videof}+#{audiof}/best'" : "-f '#{audiof}'")
          
          # Ensure we merge to mp4 if video is requested, to avoid split files causing ambiguity
          cmd << "--merge-output-format mp4" unless is_audio
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
        
        %i[referer].each { |k| cmd << "--#{k} '#{opts[k].gsub("'", "\\'")}'" if opts[k] }
        
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
