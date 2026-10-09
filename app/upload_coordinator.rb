class UploadCoordinator
  def initialize(worker)
    @worker = worker
    @album_queue = []
  end

  def upload_or_queue(input, pos)
    if worker.opts.album && Utils::MimeTypes.album_item?(input)
      album_queue << [pos, input]
    else
      upload(input)
    end
  end

  def upload(input, caption: nil)
    uploads = Array.wrap(input.uploads.presence || input)
    return upload_album(container(uploads, input), caption) if album_uploads?(uploads)

    uploads.each { |upload| worker.upload_item(upload) }
  ensure
    worker.cleanup_input(input)
  end

  def flush
    return if album_queue.empty?
    return upload(album_queue.first.second) if album_queue.one?

    inputs = album_queue.sort_by(&:first).map(&:second)
    upload container(inputs, inputs.first), caption: worker.album_caption(inputs)
  end

  private

  attr_reader :worker, :album_queue

  def upload_album(input, caption)
    worker.send_album worker.msg, caption || worker.caption_for(input), uploads: input.uploads, parse_mode: 'MarkdownV2'
  end

  def album_uploads?(uploads)
    uploads.size > 1 && uploads.all? { |up| Utils::MimeTypes.album_item?(up) }
  end

  def container(uploads, source)
    SymMash.new(info: source.info, opts: source.opts, url: source.url, type: source.type, uploads: uploads)
  end
end
