require 'faraday'
require 'faraday/multipart'
require 'rack/mime'

require_relative '../audiobook'

Faraday::UploadIO = Faraday::Multipart::FilePart unless defined?(Faraday::UploadIO)

class Bot
  class Worker

    attr_reader :bot
    attr_reader :msg
    attr_reader :st

    attr_reader :dir
    attr_reader :opts

    class_attribute :tmpdir
    self.tmpdir = ENV['TMPDIR'] || Dir.tmpdir

    delegate_missing_to :bot

    def initialize bot, msg
      @bot = bot
      @msg = msg
      load_session
    end

    def load_session
      return unless defined? Session
      @session = Session.find_or_create uid: msg.from.id
      @session.daylog.reject!{ |l| l['sent_at'].to_time < 1.day.ago }
      @session.daylog << {
        msg:     msg,
        sent_at: Time.now,
      }
      @session.msg_count += 1
      @session.save
    end

    def workdir &block
      @dir = Dir.mktmpdir "mdb-", tmpdir
      yield @dir
    ensure
      FileUtils.remove_entry dir
    end

    def process
      # Processing starts: use a single workdir for all cases
      workdir do |work_dir|
        @dir = work_dir
        procs  = []
        inputs = []

        @st = Status.new do |text, *args, **params|
          text = me text unless params[:parse_mode]
          edit_message msg, msg.resp.message_id, *args, text: text, **params
        end

        popts = {dir: work_dir, bot:, msg:, st: @st}
        klass = if msg.audio.present? || msg.video.present? || pdf_document? then Bot::FileProcessor else Bot::UrlProcessor end
        procs = msg.text.to_s.split("\n").reject(&:blank?).map { |l| klass.new line: l, **popts }
        procs << klass.new(**popts) if procs.empty? && pdf_document?
        msg.resp = send_message msg, me('Downloading metadata...')
        procs.each.with_index do |p, i|
          inputs[i] = p.download
        end
        inputs.flatten!

        return if inputs.first.blank? # error

        inputs.uniq!{ |i| i.info.display_id }
        @opts = inputs.first&.opts || SymMash.new
        inputs.sort_by!{ |i| i.info.title } if opts[:sort]
        inputs.reverse! if opts[:reverse]

        ordered  = opts[:sort] || opts[:number] || opts[:ordered] || opts[:reverse]
        up_queue = inputs.size.times.to_a

        inputs.each.with_index.api_peach do |i, pos|
          @st.add 'downloading', prefix: i.info.title do |stline|
            i.p = p = klass.new line: i.line, stline: stline, **popts

            p.download_one i, pos: pos+1 if p.respond_to? :download_one
            next if stline.error?

            stline.update 'transcoding'
            p.handle_input i, pos: pos+1
            next if stline.error?

            stline.update 'queued to upload' if ordered
            sleep 0.1 while up_queue.first != pos if ordered
            stline.update 'uploading'
            upload i
          ensure
            p.cleanup
            up_queue.delete pos
          end
        end

        return if inputs.blank? or @st.keep?
      end
      msg.resp
    end

    # --- PDF support -----------------------------------------------------

    def pdf_document?
      doc = msg.document
      doc && (doc.mime_type == 'application/pdf' || doc.file_name.to_s.downcase.end_with?('.pdf'))
    end

    def upload i
      if i.uploads.present?
        i.uploads.each do |up|
          path    = up[:path]    || up.path
          caption = up[:caption] || up.caption || ''
          mime    = up[:mime]    || up.mime    || Rack::Mime.mime_type(File.extname(path))

          io = Faraday::UploadIO.new path, mime
          send_message msg, caption, type: 'document', document: io, parse_mode: nil
        end
        return
      end

      oprobe = i.oprobe = Prober.for i.fn_out
      fn_out = i.fn_out
      type   = i.type
      info   = i.info
      durat  = i.oprobe.format.duration.to_i # speed may change from input
      opts   = i.opts

      if info.language and opts.lang
        info.title       = Translator.translate info.title,       from: info.language, to: opts.lang
        info.description = Translator.translate info.description, from: info.language, to: opts.lang if opts.description
      end

      caption = msg_caption i
      return send_message msg, caption if opts.simulate

      vstrea = oprobe&.streams&.find{ |s| s.codec_type == 'video' }
      thumb  = Faraday::UploadIO.new i.thumb, 'image/jpeg' if i.thumb
      fn_io  = Faraday::UploadIO.new fn_out, i.opts.format.mime
      paid   = ENV['PAID'] || msg.from.id.in?([6884159818])
      typek  = if paid then :media else type.name end

      media  = SymMash.new(
        type:      type.name,
        typek =>   fn_io,
        duration:  durat,
        width:     vstrea&.width,
        height:    vstrea&.height,
        thumb:     thumb,
        title:     info.title,
        performer: info.uploader,
        supports_streaming: true,
      )
      ret_msg = i.ret_msg = SymMash.new star_count: (20 if paid)
      if paid
        file = media.media
        media.media = 'attach://file'
        ret_msg.merge! media: [media], type: :paid_media, file: file
      else ret_msg.merge! media end

      pp ret_msg if ENV['DEBUG']
      caption = 'paid' if paid
      send_message msg, caption, **ret_msg
    end

    def msg_caption i
      return '' if opts.nocaption
      text = ''
      if opts.caption or i.type == Zipper::Types.video
        text  = "_#{me i.info.title}_"
        text << "\n#{me i.info.uploader}" if i.info.uploader
      end
      text << "\n\n_#{me i.info.description.strip}_" if opts.description and i.info.description.strip.presence
      text << "\n\n#{me i.url}" if i.url
      text
    end

  end
end
