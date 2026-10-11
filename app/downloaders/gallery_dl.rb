module Downloaders
  class GalleryDl < Base

    BIN        = ENV['GALLERY_DL'].presence || File.expand_path('~/.local/bin/gallery-dl')
    EXTRACTORS = File.expand_path(__dir__)

    def self.build(ctx)
      downloader = new(ctx)
      downloader if downloader.gallery_post?
    end

    def self.supports?(ctx)
      !!build(ctx)
    end

    def gallery_post?
      return false unless Utils::Safety.public_http_url?(normalized_url)

      items = self.class.rows_of(gallery_rows, 3)
      items.present? && !(items.one? && items.first.last['type'].to_s == 'video')
    end

    def download
      source_url = validate_public_url!(normalized_url)
      before = downloaded_files
      info   = gallery_info
      gopts  = gallery_opts
      _, e, s = Sh.run command, chdir: tmp
      return st.error("gallery-dl error: #{e.lines.last(3).join.strip}") unless s.success?

      files = downloaded_files - before
      return st.error('gallery-dl did not download media') if files.empty?

      SymMash.new(
        url:     source_url,
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
      cmd = [gallery_dl, '-X', EXTRACTORS, '--no-part', '--no-mtime', '-D', tmp]
      cmd.concat ['--cookies', cookie_path] if cookie_path
      cmd << normalized_url
    end

    def gallery_dl
      File.executable?(BIN) ? BIN : 'gallery-dl'
    end

    # gallery-dl prints rows of [kind, ...payload]: 2 for the post, 3 for each file.
    def self.rows_of(rows, kind) = Array(rows).select { |row| row.first == kind }

    def self.post_metadata(rows) = SymMash.new((rows_of(rows, 2).first || rows_of(rows, 3).first)&.last || {})

    def self.content_from(rows)
      meta = post_metadata(rows)
      meta.content.presence || meta.title.presence
    end

    def gallery_info
      meta = metadata
      user = meta.user || meta.author || SymMash.new
      SymMash.new(
        title:       self.class.content_from(gallery_rows) || File.basename(normalized_url.to_s),
        description: meta.description.presence,
        uploader:    user.nick.presence || user.name.presence,
        display_id:  (meta.tweet_id || meta.id || normalized_url).to_s,
        language:    meta.lang
      )
    end

    def gallery_opts
      opts.deep_dup.tap { |o| o.caption ||= 1 }
    end

    def metadata
      self.class.post_metadata(gallery_rows)
    rescue StandardError
      SymMash.new
    end

    def gallery_rows
      return ctx.gallery_rows unless ctx.gallery_rows.nil?

      out, = Sh.run [gallery_dl, '-X', EXTRACTORS, '-j', normalized_url], chdir: tmp
      ctx.gallery_rows = JSON.parse(out)
    rescue StandardError
      ctx.gallery_rows = []
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
        type:   SymMash.new(name: Utils::MimeTypes.type_for_mime(mime)),
        mime:   mime,
        opts:   gopts.deep_dup,
        url:    normalized_url,
        info:   info.merge(title: info.title.presence || title, display_id: "#{info.display_id}-#{pos}")
      )
    end
  end
end
