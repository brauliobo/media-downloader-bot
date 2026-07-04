require_relative 'base'
require_relative '../utils/cookie_jar'

module Downloaders
  class GalleryDl < Base
    Downloaders.register(self)

    HOSTS = /(?:^|\.)(?:x|twitter|instagram|bsky|tumblr|reddit|imgur|flickr|pinterest|facebook|weibo|vk)\./i
    BIN   = ENV['GALLERY_DL'].presence || File.expand_path('~/.local/bin/gallery-dl')

    def self.supports?(ctx)
      URI(ctx.url.to_s).host.to_s.match?(HOSTS)
    rescue URI::InvalidURIError
      false
    end

    def download
      before = downloaded_files
      _, e, s = Sh.run command, chdir: tmp
      return st.error("gallery-dl error: #{e.lines.last(3).join.strip}") unless success?(s)

      files = downloaded_files - before
      return st.error('gallery-dl did not download media') if files.empty?

      SymMash.new(
        url:     url,
        opts:    opts.deep_dup,
        info:    SymMash.new(title: File.basename(url.to_s), display_id: url.to_s),
        uploads: files.map.with_index { |file, i| upload(file, i + 1) }
      )
    end

    def download_one(_input, **_kwargs)
      true
    end

    private

    def command
      cmd = [gallery_dl, '--no-part', '--no-mtime', '-D', tmp]
      cmd.concat ['--cookies', cookie_path] if cookie_path
      cmd << url.to_s
    end

    def gallery_dl
      File.executable?(BIN) ? BIN : 'gallery-dl'
    end

    def success?(status)
      status.respond_to?(:success?) ? status.success? : status == 0
    end

    def cookie_path
      @cookie_path ||= Utils::CookieJar.write(session, tmp)
    rescue StandardError => e
      st.error "Cookie error: #{e.class}: #{e.message}"
      nil
    end

    def downloaded_files
      Dir[File.join(tmp, '**', '*')].select { |f| File.file?(f) }.sort
    end

    def upload(file, pos)
      title = File.basename(file, File.extname(file))
      SymMash.new(
        fn_out: file,
        type:   SymMash.new(name: :document),
        mime:   Rack::Mime.mime_type(File.extname(file)) || 'application/octet-stream',
        opts:   opts.deep_dup,
        url:    url,
        info:   SymMash.new(title: title, display_id: "#{url}-#{pos}")
      )
    end
  end
end
