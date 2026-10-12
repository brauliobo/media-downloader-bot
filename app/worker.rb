
class Worker
  include StatusMessage

  ALBUM_CAPTION_SEPARATOR = "\n\n".freeze

  class_attribute :service, :workdir_path, :skip_cleanup
  class_attribute :tmpdir, default: Utils::Tmp.root

  attr_reader :msg, :st, :dir, :opts, :session, :job_id, :service, :tmpdir, :workdir_path, :skip_cleanup

  def initialize(msg, service: self.class.service, job_id: nil, tmpdir: self.class.tmpdir, workdir_path: self.class.workdir_path, skip_cleanup: self.class.skip_cleanup)
    @msg          = msg
    @service      = service
    @job_id       = job_id
    @tmpdir       = tmpdir
    @workdir_path = workdir_path
    @skip_cleanup = skip_cleanup
    load_session
  end

  delegate :send_message, :send_album, :edit_message, :delete_message, :download_file, :report_error, :msg_limit, to: :service

  def load_session
    return unless ENV['DB']
    @session = Session.find_or_create uid: ENV['SESSION_UID'] || msg.from.id
    @session.daylog.reject!{ |l| l['sent_at'].to_time < 1.day.ago }
    @session.daylog << {sent_at: Time.now}
    @session.msg_count += 1
    @session.save
  end

  def process
    cancelled = false
    run
  rescue Bot::JobCancelled
    cancelled = true
    @st&.error('Cancelled', cancel_job: false)
    raise
  rescue Bot::JobRestarted
    cancelled = true
    @st&.error('Restarting...', cancel_job: false)
    raise
  rescue StandardError => e
    @st&.error('Processing error', exception: e)
    report_error(msg, e)
  ensure
    clear_cancel_button unless cancelled
  end

  def run
    finished = workdir do |work_dir|
      @dir = work_dir
      init_status

      ctx = Context.new(dir: work_dir, msg: msg, st: @st, session: @session, service: service)
      ctx.tmp = Utils::Tmp.dir('input-', work_dir)
      Utils::Tmp.within(ctx.tmp) { process_inputs(ctx) }
    end
    msg.resp if finished
  end

  # Whether the job ran to the end, so the response is worth returning.
  def process_inputs(ctx)
    inputs = collect_inputs(ctx)

    return if inputs.first.blank? and @st&.error?
    return @st&.error('No inputs generated') if inputs.first.blank?

    order_inputs!(inputs)

    ordered  = opts[:sort] || opts[:number] || opts[:ordered] || opts[:reverse]
    up_queue = inputs.size.times.to_a
    uploader = UploadCoordinator.new(self)

    inputs.each.with_index.api_peach(threads: peach_threads) do |i, pos|
      process_input(i, pos: pos, total: inputs.size, ordered: ordered, up_queue: up_queue, uploader: uploader)
    end

    uploader.flush

    inputs.map(&:processor).uniq.each(&:cleanup) unless skip_cleanup
    !@st.keep?
  end

  def collect_inputs(ctx)
    lines = Utils::InputParser.message_lines(msg)
    process_lines(lines, ctx).flat_map { |p| Array.wrap p.process }
  end

  def order_inputs!(inputs)
    inputs.uniq!{ |i| i.info.display_id }
    @opts = inputs.first&.opts || SymMash.new
    inputs.sort_by!{ |i| i.info.title } if opts[:sort]
    inputs.reverse! if opts[:reverse]
  end

  # The queue position is released in an ensure so a failed input never holds up the ones behind it.
  def process_input(i, pos:, total:, ordered:, up_queue:, uploader:)
    output_pos = total > 1 ? pos + 1 : nil
    @st.add 'downloading', prefix: i.info.title do |stline|
      i.p = p = i.processor
      i.stl = p.stl = stline

      p.download_one i, pos: output_pos
      next if stline.error?

      p.handle_input i, pos: output_pos
      next if stline.error?

      stline.update 'queued to upload' if ordered
      sleep 0.1 while up_queue.first != pos if ordered
      t = i.type&.name || i.type
      stline.update "uploading #{t}"
      uploader.upload_or_queue i, pos

    rescue => e
      if (user_message = e.try(:user_message))
        stline.error user_message
      else
        stline.error "Processing error", exception: e
      end
      report_error(msg, e)
    ensure
      up_queue.delete pos
    end
  end

  def upload i
    UploadCoordinator.new(self).upload(i)
  end

  def upload_item i
    # Treat documents (e.g., SRT-only) via standard path using fn_out/type
    media_type = Utils::MimeTypes.telegram_type(i)
    is_doc = media_type == :document
    oprobe = (i.oprobe ||= Prober.for i.fn_out) if %i[audio video].include?(media_type)
    info   = i.info
    durat  = oprobe&.format&.duration&.to_i
    opts   = i.opts

    info.title = msg_limit(info.title, percent: 90) if info.title

    caption = caption_for(i)
    return send_message msg, caption if opts.simulate

    vstrea     = Prober.video_stream(oprobe)
    thumb_path = i.thumbnail_path || i.thumb
    mime       = i.mime.presence || i.opts.format&.mime || 'application/octet-stream'
    file_path  = i.fn_out

    paid = (ENV['PAID'] || msg.from.id.in?([6884159818])) && !is_doc
    media  = SymMash.new(
      type: media_type, duration: durat, width: vstrea&.width, height: vstrea&.height,
      title: info.title, performer: info.uploader, supports_streaming: true, thumb_path: thumb_path
    )
    ret_msg = i.ret_msg = SymMash.new star_count: (20 if paid)
    if paid
      media.merge!(media: 'attach://file', media_path: file_path, media_mime: mime)
      ret_msg.merge!(media: [media], type: :paid_media, file_path: file_path, file_mime: mime)
    else
      ret_msg.merge!(media, file_path: file_path, file_mime: mime)
    end

    ret_msg[:type] ||= media_type

    pp ret_msg if ENV['DEBUG']
    caption = 'paid' if paid
    send_message msg, caption, **ret_msg
  end

  def caption_limit
    service.try(:max_caption) || Bot::MsgHelpers::MEDIA_CAPTION_LIMIT
  end

  def caption_for(input, max: caption_limit)
    caption = Caption.new(opts)
    caption.render(input, max: max, info: caption.translate_info(input.info, input.opts))
  end

  # One caption per item (title, source link, ...) sharing the album caption limit.
  def album_caption(inputs)
    budget = (caption_limit - ALBUM_CAPTION_SEPARATOR.size * (inputs.size - 1)) / inputs.size
    inputs.map { |input| caption_for(input, max: budget) }.reject(&:blank?).join(ALBUM_CAPTION_SEPARATOR)
  end

  # Where a job keeps its files, and clearing them afterwards.
  def workdir &block
    cancelled = false
    @dir = workdir_path || Utils::Tmp.dir('mdb-', tmpdir)
    yield @dir
  rescue Bot::JobCancelled
    cancelled = true
    FileUtils.rm_rf(@dir) unless skip_cleanup
    raise
  ensure
    cleanup_workdir(@dir) unless skip_cleanup || cancelled
  end

  def cleanup_workdir(dir)
    return unless dir && Dir.exist?(dir)
    # Detached subprocess survives parent fork exit; delay lets uploaders release file handles
    pid = Process.spawn('sh', '-c', "sleep 30 && rm -rf #{dir.shellescape}", out: File::NULL, err: File::NULL)
    Process.detach pid
  end

  def cleanup_input(input)
    return if skip_cleanup || !dir

    Array(input.uploads).each { |upload| cleanup_input(upload) }

    root = "#{File.expand_path(dir)}/"
    %i[fn_in fn_out thumb thumbnail_path].filter_map { |name| input.public_send(name) }.uniq.each do |path|
      path = File.expand_path(path)
      FileUtils.rm_f(path) if path.start_with?(root)
    end
  end

  private

  def peach_threads
    Enumerable.admin_threads(Bot::MsgHelpers.from_admin?(msg), opts.threads)
  end

  def process_lines(lines, ctx)
    processors = Processors::Router.for_message(ctx, lines)
    if processors
      processors
    else
      @st&.error('No URL or media provided')
      []
    end
  end
end
