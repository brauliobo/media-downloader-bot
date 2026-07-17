require_relative 'base'
require_relative '../utils/cookie_jar'

module Downloaders
  class GalleryDl < Base
    Downloaders.register(self)

    BIN = ENV['GALLERY_DL'].presence || File.expand_path('~/.local/bin/gallery-dl')

    def self.supports?(ctx)
      new(ctx).gallery_post?
    end

    def gallery_post?
      validate_public_url!(url)
      items = gallery_rows.select { |item| item.is_a?(Array) && item.first == 3 }
      items.present? && !(items.one? && items.first.last['type'].to_s == 'video')
    end

    def download
      validate_public_url!(url)
      before = downloaded_files
      info   = gallery_info
      gopts  = gallery_opts
      _, e, s = Sh.run command, chdir: tmp
      return st.error("gallery-dl error: #{e.lines.last(3).join.strip}") unless success?(s)

      files = downloaded_files - before
      return st.error('gallery-dl did not download media') if files.empty?

      SymMash.new(
        url:     url,
        opts:    gopts,
        info:    info,
        uploads: files.map.with_index { |file, i| upload(file, i + 1, info, gopts) }
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

    def gallery_info
      meta = metadata
      user = meta.user || meta.author || SymMash.new
      SymMash.new(
        title:       meta.content.presence || meta.title.presence || File.basename(url.to_s),
        description: meta.description.presence,
        uploader:    user.nick.presence || user.name.presence,
        display_id:  (meta.tweet_id || meta.id || url).to_s,
        language:    meta.lang
      )
    end

    def gallery_opts
      opts.deep_dup.tap { |o| o.caption ||= 1 }
    end

    def metadata
      rows = gallery_rows
      row  = rows.find { |item| item.is_a?(Array) && item.first == 2 } || rows.find { |item| item.is_a?(Array) && item.first == 3 }
      SymMash.new(row&.last || {})
    rescue StandardError
      SymMash.new
    end

    def gallery_rows
      out, = Sh.run [gallery_dl, '-j', url.to_s], chdir: tmp
      JSON.parse(out)
    rescue StandardError
      []
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

    def upload(file, pos, info, gopts)
      title = File.basename(file, File.extname(file))
      mime  = Rack::Mime.mime_type(File.extname(file)) || 'application/octet-stream'
      SymMash.new(
        fn_out: file,
        type:   SymMash.new(name: mime.start_with?('video/') ? :video : :document),
        mime:   mime,
        opts:   gopts.deep_dup,
        url:    url,
        info:   info.merge(title: info.title.presence || title, display_id: "#{info.display_id}-#{pos}")
      )
    end
  end
end
