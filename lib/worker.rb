require_relative 'boot'

require_relative 'utils/sh'
require_relative 'utils/url_shortener'
require_relative 'bot/msg_helpers'
require_relative 'models/session' if ENV['DB']
require_relative 'context'

require_relative 'prober'
require_relative 'zipper'
require_relative 'translator'
require_relative 'tagger'
require_relative 'downloaders'
require_relative 'upload_coordinator'

require_relative 'processors/base'
require_relative 'processors/router'
require_relative 'processors/url'
require_relative 'processors/document'
require_relative 'processors/media'
require_relative 'processors/shorts'
require_relative 'processors/local_file'

require_relative 'bot/status'
require_relative 'bot/jobs'
require_relative 'bot/worker/client'

require_relative 'audiobook'

Faraday::UploadIO = Faraday::Multipart::FilePart unless defined?(Faraday::UploadIO)

class Worker

  class_attribute :service

  attr_reader :msg
  attr_reader :st
  attr_reader :dir
  attr_reader :opts
  attr_reader :session
  attr_reader :service
  attr_reader :job_id

  class_attribute :tmpdir
  self.tmpdir = ENV['TMPDIR'] || Dir.tmpdir

  class_attribute :workdir_path
  class_attribute :skip_cleanup

  attr_reader :tmpdir
  attr_reader :workdir_path
  attr_reader :skip_cleanup

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
    return unless defined? Models::Session
    @session = Models::Session.find_or_create uid: ENV['SESSION_UID'] || msg.from.id
    @session.daylog.reject!{ |l| l['sent_at'].to_time < 1.day.ago }
    @session.daylog << {sent_at: Time.now}
    @session.msg_count += 1
    @session.save
  end

  def workdir &block
    cancelled = false
    @dir = workdir_path || Dir.mktmpdir("mdb-", tmpdir)
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

  def process
    cancelled = false
    run
  rescue Bot::JobCancelled
    cancelled = true
    @st&.error('Cancelled', cancel_job: false)
    raise
  ensure
    clear_cancel_button unless cancelled
  end

  def run
    workdir do |work_dir|
      @dir = work_dir
      procs  = []
      inputs = []
      init_status

      ctx = Context.new(dir: work_dir, msg: msg, st: @st, session: @session, service: service)
      
      lines = Utils::InputParser.message_lines(msg)
      procs = process_lines(lines, ctx)
      
      procs.each do |p|
        inputs.concat Array.wrap p.process
      end

      return if inputs.first.blank? and @st&.error?
      return @st&.error('No inputs generated') if inputs.first.blank?

      inputs.uniq!{ |i| i.info.display_id }
      @opts = inputs.first&.opts || SymMash.new
      inputs.sort_by!{ |i| i.info.title } if opts[:sort]
      inputs.reverse! if opts[:reverse]

      ordered  = opts[:sort] || opts[:number] || opts[:ordered] || opts[:reverse]
      up_queue = inputs.size.times.to_a
      uploader = UploadCoordinator.new(self)

      inputs.each.with_index.api_peach do |i, pos|
        output_pos = inputs.size > 1 ? pos + 1 : nil
        @st.add 'downloading', prefix: i.info.title do |stline|
          i.p = p = i.processor
          i.stl = p.stl = stline

          p.download_one i, pos: output_pos if p.respond_to? :download_one
          next if stline.error?

          stline.update 'transcoding'
          p.handle_input i, pos: output_pos
          next if stline.error?

          stline.update 'queued to upload' if ordered
          sleep 0.1 while up_queue.first != pos if ordered
          t = i.type&.name || i.type
          stline.update "uploading #{t}"
          uploader.upload_or_queue i, pos

        rescue => e
          if e.respond_to?(:user_message)
            stline.error e.user_message
          else
            stline.error "Processing error", exception: e
          end
          report_error(msg, e)
        ensure
          up_queue.delete pos
        end
      end

      uploader.flush

      inputs.map(&:processor).uniq.each(&:cleanup)
      return if inputs.blank? or @st.keep?
    end
    msg.resp
  end

  def upload i
    UploadCoordinator.new(self).upload(i)
  end

  def cleanup_input(input)
    return if skip_cleanup || !dir

    Array(input.uploads).each { |upload| cleanup_input(upload) } if input.respond_to?(:uploads)

    root = "#{File.expand_path(dir)}/"
    %i[fn_in fn_out thumb thumbnail_path].filter_map do |name|
      input.public_send(name) if input.respond_to?(name)
    end.uniq.each do |path|
      path = File.expand_path(path)
      FileUtils.rm_f(path) if path.start_with?(root)
    end
  end

  def caption_limit
    service.respond_to?(:max_caption) ? service.max_caption : 1024
  end

  private

  def process_lines(lines, ctx)
    processors = Processors::Router.for_message(ctx, lines)
    if processors
      processors
    else
      @st&.error('No URL or media provided')
      []
    end
  end

  def init_status
    return if @st
    @st = Bot::Status.new(on_empty: -> { delete_status_message }) do |text, *args, **params|
      params[:cancel_job] = job_id if job_id && !params.key?(:cancel_job)
      @status_update = [text, args, params]
      raw = text
      text = Bot::MsgHelpers.me(text) unless params[:parse_mode]
      force = params[:cancel_job] == false
      begin
        edit_message msg, msg.resp.message_id, *args, text: text, force: force, **params
      rescue
        # Fallback: retry without MarkdownV2 so error messages with special chars still display
        edit_message(msg, msg.resp.message_id, text: raw, force: force, parse_mode: nil, cancel_job: params[:cancel_job]) rescue nil
      end
    end
    initial_params = job_id ? {cancel_job: job_id} : {}
    initial_text   = 'Downloading metadata...'
    @status_update = [initial_text, [], initial_params]
    msg.resp ||= send_message msg, Bot::MsgHelpers.me(initial_text), **initial_params
  end

  def delete_status_message
    delete_message(msg, msg.resp.message_id, wait: 0) if msg.resp&.message_id
    @status_deleted = true
  end

  def clear_cancel_button
    return unless job_id && !@status_deleted && @status_update && msg.resp&.message_id

    text, args, params = @status_update
    params = params.merge(cancel_job: false)
    raw    = text
    text   = Bot::MsgHelpers.me(text) unless params[:parse_mode]
    edit_message(msg, msg.resp.message_id, *args, text: text, force: true, **params)
  rescue
    edit_message(msg, msg.resp.message_id, text: raw, force: true, parse_mode: nil, cancel_job: false) rescue nil
  end

  def upload_one i
    # Treat documents (e.g., SRT-only) via standard path using fn_out/type
    type_name = i.type&.name
    type_name = type_name.to_sym if type_name.respond_to?(:to_sym)
    is_doc = (type_name == :document)
    oprobe = (i.oprobe ||= Prober.for i.fn_out) unless is_doc
    info   = i.info
    durat  = oprobe&.format&.duration&.to_i
    opts   = i.opts

    caption_info = translate_caption_info(info, opts)

    info.title = msg_limit(info.title, percent: 90) if info.title

    caption = msg_caption i, max: caption_limit, info: caption_info
    return send_message msg, caption if opts.simulate

    vstrea     = oprobe&.streams&.find{ |s| s.codec_type == 'video' }
    thumb_path = i.thumbnail_path || i.thumb
    mime       = i.mime.presence || i.opts.format&.mime || 'application/octet-stream'
    file_path  = i.fn_out

    paid = (ENV['PAID'] || msg.from.id.in?([6884159818])) && !is_doc
    type = i.type

    media  = SymMash.new(
      type: type.name, duration: durat, width: vstrea&.width, height: vstrea&.height,
      title: info.title, performer: info.uploader, supports_streaming: true, thumb_path: thumb_path
    )
    ret_msg = i.ret_msg = SymMash.new star_count: (20 if paid)
    if paid
      media.merge!(media: 'attach://file', media_path: file_path, media_mime: mime)
      ret_msg.merge!(media: [media], type: :paid_media, file_path: file_path, file_mime: mime)
    else
      ret_msg.merge!(media, file_path: file_path, file_mime: mime)
    end

    ret_msg[:type] ||= type.name

    pp ret_msg if ENV['DEBUG']
    caption = 'paid' if paid
    send_message msg, caption, **ret_msg
  end

  def msg_caption(i, max: nil, info: i.info)
    caption_opts = i.opts || opts || SymMash.new
    return '' if caption_opts.nocaption

    return build_msg_caption(i, info: info) unless max

    title = info.title.to_s
    best  = nil
    low   = 0
    high  = title.size

    while low <= high
      mid  = (low + high) / 2
      text = build_msg_caption(i, title: title.first(mid), info: info)
      if text.size <= max
        best = text
        low  = mid + 1
      else
        high = mid - 1
      end
    end

    best || build_msg_caption(i, title: '', info: info)
  end

  def build_msg_caption(i, title: nil, info: i.info)
    caption_opts = i.opts || opts || SymMash.new
    text = ''
    if caption_opts.caption or i.type == Zipper::Types.video
      title_text = (title || info.title).to_s
      text  = markdown_italic(title_text) if title_text.present?
      text << "\n" if text.present? && info.uploader
      text << Bot::MsgHelpers.me(info.uploader) if info.uploader
    end
    if caption_opts.description and info.description.strip.presence
      text << "\n\n" if text.present?
      text << markdown_italic(info.description.strip)
    end
    if i.url
      text << "\n\n" if text.present?
      text << Bot::MsgHelpers.me(i.url)
    end
    text
  end

  def markdown_italic(text)
    text.to_s.split(/(\n+)/).map do |part|
      part.match?(/\A\n+\z/) || part.empty? ? part : "_#{Bot::MsgHelpers.me(part)}_"
    end.join
  end

  def translate_caption_text(text, from:, to:)
    urls = text.to_s[%r{(?:\s+https?://\S+)+\s*\z}]
    body = urls ? text.to_s.delete_suffix(urls).strip : text.to_s
    [translate_caption_body(body, from: from, to: to), urls.to_s.strip.presence].compact.join(' ')
  end

  def translate_caption_body(body, from:, to:)
    parts = body.to_s.split(/(\n{2,})/)
    parts.map do |part|
      if part.blank? || part.match?(/\A\n+\z/)
        part
      else
        translate_caption_segment(part, from: from, to: to)
      end
    end.join
  end

  def translate_caption_segment(text, from:, to:)
    chunks = text.to_s.split(/(?<=[.!?])\s+/)
    return Translator.translate(text, from: from, to: to) if chunks.one?

    Array(Translator.translate(chunks, from: from, to: to)).join(' ')
  end

  def translate_caption_info(info, opts)
    target = opts.clang || opts.slang
    return info unless target

    caption_info = opts.clang ? info.deep_dup : info
    [:title, (:description if opts.description)].compact.each do |field|
      caption_info[field] = translate_caption_text(info[field], from: info.language, to: target) if info[field].present?
    end
    caption_info
  end

end
