class UploadCoordinator
  ALBUM_CAPTION_LIMIT = 1024

  def initialize(worker)
    @worker = worker
    @album_queue = []
  end

  def upload_or_queue(input, pos)
    if worker.opts.album && album_item?(input)
      album_queue << [pos, input]
    else
      upload(input)
    end
  end

  def upload(input)
    if input.uploads.present?
      return upload_album(container(input.uploads, input)) if album_uploads?(input.uploads)

      input.uploads.each { |up| worker.send(:upload_one, up) }
    else
      worker.send(:upload_one, input)
    end
  end

  def flush
    return if album_queue.empty?
    return upload(album_queue.first.second) if album_queue.one?

    upload_album container(album_queue.sort_by(&:first).map(&:second), album_queue.first.second)
  end

  private

  attr_reader :worker, :album_queue

  def upload_album(input)
    worker.send(:translate_caption_info, input.info, input.opts)
    worker.send_album worker.msg, album_caption(input), uploads: input.uploads, parse_mode: 'MarkdownV2'
  end

  def album_caption(input)
    worker.send(:msg_caption, input).to_s.first(ALBUM_CAPTION_LIMIT)
  end

  def album_uploads?(uploads)
    uploads.size > 1 && uploads.all? { |up| album_item?(up) }
  end

  def album_item?(input)
    input.mime.to_s.start_with?('image/', 'video/') && File.exist?(input.fn_out.to_s)
  end

  def container(uploads, source)
    SymMash.new(info: source.info, opts: source.opts, url: source.url, type: source.type, uploads: uploads)
  end
end
