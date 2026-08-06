require_relative 'utils/mime_types'

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

  def upload(input)
    if input.uploads.present?
      return upload_album(container(input.uploads, input)) if album_uploads?(input.uploads)

      input.uploads.each { |up| worker.send(:upload_one, up) }
    else
      worker.send(:upload_one, input)
    end
  ensure
    worker.cleanup_input(input)
  end

  def flush
    return if album_queue.empty?
    return upload(album_queue.first.second) if album_queue.one?

    upload container(album_queue.sort_by(&:first).map(&:second), album_queue.first.second)
  end

  private

  attr_reader :worker, :album_queue

  def upload_album(input)
    caption = worker.send(:caption_for, input)
    worker.send_album worker.msg, caption, uploads: input.uploads, parse_mode: 'MarkdownV2'
  end

  def album_uploads?(uploads)
    uploads.size > 1 && uploads.all? { |up| Utils::MimeTypes.album_item?(up) }
  end

  def container(uploads, source)
    SymMash.new(info: source.info, opts: source.opts, url: source.url, type: source.type, uploads: uploads)
  end
end
