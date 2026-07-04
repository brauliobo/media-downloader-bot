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

  class_attribute :tmpdir
  self.tmpdir = ENV['TMPDIR'] || Dir.tmpdir

  class_attribute :workdir_path
  class_attribute :skip_cleanup

  def initialize msg
    @msg = msg
    load_session
  end

  delegate :send_message, :send_album, :edit_message, :delete_message, :download_file, :report_error, :msg_limit, to: :service

  def load_session
    return unless defined? Models::Session
    @session = Models::Session.find_or_create uid: ENV['SESSION_UID'] || msg.from.id
    @session.daylog.reject!{ |l| l['sent_at'].to_time < 1.day.ago }
    @session.daylog << {
      msg:     msg,
      sent_at: Time.now,
    }
    @session.msg_count += 1
    @session.save
  end

  def workdir &block
    @dir = workdir_path || Dir.mktmpdir("mdb-", tmpdir)
    yield @dir
  ensure
    cleanup_workdir(@dir) unless skip_cleanup
  end

  def cleanup_workdir(dir)
    return unless dir && Dir.exist?(dir)
    # Detached subprocess survives parent fork exit; delay lets uploaders release file handles
    pid = Process.spawn('sh', '-c', "sleep 30 && rm -rf #{dir.shellescape}", out: File::NULL, err: File::NULL)
    Process.detach pid
  end

  def process
    run
  end

  def run
    workdir do |work_dir|
      @dir = work_dir
      procs  = []
      inputs = []
      init_status

      ctx = Context.new(dir: work_dir, msg: msg, st: @st, session: @session)
      
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
      raw = text
      text = Bot::MsgHelpers.me(text) unless params[:parse_mode]
      begin
        result = edit_message msg, msg.resp.message_id, *args, text: text, force: true, **params
        raise 'edit failed' unless result
      rescue
        # Fallback: retry without MarkdownV2 so error messages with special chars still display
        edit_message(msg, msg.resp.message_id, text: raw, force: true, parse_mode: nil) rescue nil
      end
    end
    msg.resp ||= send_message msg, Bot::MsgHelpers.me('Downloading metadata...')
  end

  def delete_status_message
    delete_message(msg, msg.resp.message_id, wait: 0) if msg.resp&.message_id
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

    translate_caption_info(info, opts)

    info.title = msg_limit(info.title, percent: 90) if info.title

    caption = msg_caption i
    return send_message msg, caption if opts.simulate

    vstrea     = oprobe&.streams&.find{ |s| s.codec_type == 'video' }
    thumb_path = i.thumbnail_path || i.thumb
    mime       = i.mime.presence || i.opts.format&.mime || 'application/octet-stream'
    file_path  = i.fn_out

    # Common send logic for both cases
    paid  = (ENV['PAID'] || msg.from.id.in?([6884159818])) && !is_doc
    type  = i.type
    typek = paid ? :media : type.name

    media  = SymMash.new(
      type: type.name, duration: durat, width: vstrea&.width, height: vstrea&.height,
      title: info.title, performer: info.uploader, supports_streaming: true
    )
    media.merge!(
      "#{typek}_path".to_sym => file_path, "#{typek}_mime".to_sym => mime,
      thumb_path: thumb_path
    )
    ret_msg = i.ret_msg = SymMash.new star_count: (20 if paid)
    if paid
      media[:media] = 'attach://file'
      ret_msg.merge!(media: [media], type: :paid_media, file_path: file_path, file_mime: mime)
    else ret_msg.merge! media end

    # Ensure endpoint type is set for non-paid media (video/audio/document)
    ret_msg[:type] ||= type.name

    pp ret_msg if ENV['DEBUG']
    caption = 'paid' if paid
    send_message msg, caption, **ret_msg
  end

  def msg_caption(i, max: nil)
    return '' if opts.nocaption

    return build_msg_caption(i) unless max

    title = i.info.title.to_s
    loop do
      text = build_msg_caption(i, title: title)
      return text if text.size <= max || title.empty?

      title = title.first([title.size - (text.size - max) - 1, 0].max)
    end
  end

  def build_msg_caption(i, title: nil)
    text = ''
    if opts.caption or i.type == Zipper::Types.video
      text  = "_#{Bot::MsgHelpers.me(title || i.info.title)}_"
      text << "\n#{Bot::MsgHelpers.me(i.info.uploader)}" if i.info.uploader
    end
    text << "\n\n_#{Bot::MsgHelpers.me(i.info.description.strip)}_" if opts.description and i.info.description.strip.presence
    text << "\n\n#{Bot::MsgHelpers.me(i.url)}" if i.url
    text
  end

  def translate_caption_text(text, from:, to:)
    urls = text.to_s[%r{(?:\s+https?://\S+)+\s*\z}]
    body = urls ? text.to_s.delete_suffix(urls).strip : text.to_s
    [Translator.translate(body, from: from, to: to), urls.to_s.strip.presence].compact.join(' ')
  end

  def translate_caption_info(info, opts)
    return unless opts.slang

    [:title, (:description if opts.description)].compact.each do |field|
      info[field] = translate_caption_text(info[field], from: info.language, to: opts.slang) if info[field].present?
    end
  end

end
