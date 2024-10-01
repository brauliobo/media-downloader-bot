class Bot
  class Worker

    attr_reader :bot
    attr_reader :msg
    attr_reader :st

    attr_reader :dir
    attr_reader :opts

    delegate_missing_to :bot

    class_attribute :tmpdir
    self.tmpdir = ENV['TMPDIR'] || Dir.tmpdir

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

    def process
      Dir.mktmpdir "mdb-", tmpdir do |dir|
        @dir   = dir
        procs  = []
        inputs = []

        @st = Status.new do |text, *args, **params|
          text = me text unless params[:parse_mode]
          edit_message msg, msg.resp.message_id, *args, text: text, **params
        end

        popts = {dir:, bot:, msg:, st: @st}
        klass = if msg.audio.present? or msg.video.present? then Bot::FileProcessor else Bot::UrlProcessor end
        procs = msg.text.split("\n").flat_map do |l|
          klass.new line: l, **popts
        end

        msg.resp = send_message msg, me('Downloading metadata...')
        procs.each.with_index do |p, i|
          inputs[i] = p.download
        end
        inputs.flatten!

        inputs.uniq!{ |i| i.info.display_id }
        @opts = inputs.first&.opts || SymMash.new
        inputs.sort_by!{ |i| i.info.title } if opts[:sort]
        inputs.reverse! if opts[:reverse]

        ordered  = opts[:sort] || opts[:number] || opts[:ordered] || opts[:reverse]
        up_queue = inputs.size.times.to_a

        inputs.each.with_index.api_peach do |i, pos|
          @st.add "#{i.info.title}: downloading" do |stline|
            i.p = p = klass.new line: i.line, stline: stline, **popts

            p.download_one i, pos: pos+1 if p.respond_to? :download_one
            next if stline.error?

            stline.update "#{i.info.title}: converting"
            p.handle_input i, pos: pos+1
            next if stline.error?

            stline.update "#{i.info.title}: queued to upload" if ordered
            sleep 0.1 while up_queue.first != pos if ordered
            stline.update "#{i.info.title}: uploading"
            upload i

          ensure
            p.cleanup
            up_queue.delete pos
          end
        end

        return msg.resp = nil if inputs.blank?
      end
      msg.resp
    end

    def upload i
      oprobe = i.oprobe = Prober.for i.fn_out
      fn_out = i.fn_out
      type   = i.type
      info   = i.info
      durat  = i.oprobe.format.duration.to_i # speed may change from input
      opts   = i.opts

      caption = msg_caption i
      return send_message msg, caption if opts.simulate

      vstrea = oprobe&.streams&.find{ |s| s.codec_type == 'video' }
      thumb  = Faraday::UploadIO.new i.thumb, 'image/jpeg' if i.thumb
      fn_io  = Faraday::UploadIO.new fn_out, i.opts.format.mime
      paid   = ENV['PAID'] || msg.from.id.in?([6884159818])
      typek  = if paid then :media else type.name end

      if info.language and opts.lang
        info.title = Translator.translate info.title, from: info.language, to: opts.lang
      end

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
