require 'faraday'
require 'faraday/multipart'
require 'rack/mime'

require_relative '../audiobook'

Faraday::UploadIO = Faraday::Multipart::FilePart unless defined?(Faraday::UploadIO)

module Bot
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
      return unless defined? Models::Session
      @session = Models::Session.find_or_create uid: msg.from.id
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
      # For TDBot, delay cleanup to allow async uploads to complete
      if bot.td_bot?
        cleanup_dir = @dir
        Thread.new do
          sleep 30 # Give TDBot time to upload files
          FileUtils.remove_entry cleanup_dir if Dir.exist?(cleanup_dir)
        end
      else
        FileUtils.remove_entry @dir
      end
    end

    def wait_in_queue(status_text)
      init_status
      @queue_line = @st.add(status_text) { |line| line.keep }
    end

    def process
      @queue_line&.tap { |line| @st&.delete(line); @queue_line = nil }
      workdir do |work_dir|
        @dir = work_dir
        procs  = []
        inputs = []
        init_status

        popts = {dir: work_dir, bot:, msg:, st: @st}
        lines = msg.text.to_s.split("\n").reject(&:blank?)
        doc   = pdf_document? || epub_document?
        media = msg.audio.present? || msg.video.present?

        if lines.present?
          has_url = lines.any? { |l| l =~ URI::DEFAULT_PARSER.make_regexp }
          if has_url
            klass = Processors::Url
            procs = lines.map { |l| klass.new line: l, **popts }
          elsif doc
            klass = Processors::Document
            procs = [klass.new(line: lines.join(' '), **popts)]
          elsif media
            klass = Processors::File
            procs = [klass.new(line: lines.join(' '), **popts)]
          else
            klass = Processors::Url
            procs = lines.map { |l| klass.new line: l, **popts }
          end
        else
          if doc
            klass = Processors::Document
            procs = [klass.new(**popts)]
          elsif media
            klass = Processors::File
            procs = [klass.new(**popts)]
          else
            klass = Processors::Url
            procs = []
          end
        end
        procs.each.with_index do |p, i|
          inputs[i] = p.process
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

    def epub_document?
      doc = msg.document
      fname = doc&.file_name.to_s.downcase
      doc && (doc.mime_type == 'application/epub+zip' || fname.end_with?('.epub'))
    end

    def upload i
      if i.uploads.present?
        i.uploads.each { |up| upload_one up }
      else
        upload_one i
      end
    end

    private

    def init_status
      return if @st
      @st = Bot::Status.new do |text, *args, **params|
        text = me text unless params[:parse_mode]
        edit_message msg, msg.resp.message_id, *args, text: text, **params
      end
      msg.resp ||= send_message msg, me('Downloading metadata...')
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

      if info.language and opts.lang
        info.title       = Translator.translate info.title,       from: info.language, to: opts.lang
        info.description = Translator.translate info.description, from: info.language, to: opts.lang if opts.description
      end

      caption = msg_caption i
      return send_message msg, caption if opts.simulate

      vstrea = oprobe&.streams&.find{ |s| s.codec_type == 'video' }
      thumb_path = i.thumb if i.thumb
      mime  = i.mime.presence || i.opts.format&.mime || 'application/octet-stream'
      file_path = i.fn_out

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
        thumb_path: thumb_path, thumbnail_path: thumb_path
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
