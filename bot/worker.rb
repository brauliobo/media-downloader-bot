class Bot::Worker

  attr_reader :bot
  attr_reader :msg
  attr_reader :dir
  attr_reader :opts

  delegate_missing_to :bot

  class_attribute :tmpdir
  self.tmpdir = ENV['TMPDIR'] || Dir.tmpdir

  def initialize bot, msg
    @bot = bot
    @msg = msg
  end

  def process
    Dir.mktmpdir "mdb-", tmpdir do |dir|
      @dir   = dir
      procs  = []
      inputs = []

      msg.resp = send_message msg, me('Downloading...')

      if msg.audio.present? or msg.video.present?
        procs << Bot::FileProcessor.new(dir, bot, msg)
      else
        procs = msg.text.split("\n").flat_map do |l|
          Bot::UrlProcessor.new dir, l, bot, msg
        end
      end

      procs.each.with_index.api_peach do |p, i|
        inputs[i] = p.download if p.respond_to? :download
      end
      inputs.flatten!
      inputs.compact!
      return msg.resp = nil if inputs.blank?

      edit_message msg, msg.resp.message_id, text: (msg.resp.text << me("\nConverting..."))
      inputs.each.with_index.api_peach do |i, pos|
        p = Bot::Processor.new dir, bot, msg
        p.handle_input i, pos: pos+1
        p.cleanup
      rescue => e
        input_error e, i
      end

      edit_message msg, msg.resp.message_id, text: (msg.resp.text << me("\nSending..."))

      @opts = inputs.first.opts
      inputs.sort_by!{ |i| i.info.title } if opts[:sort]
      inputs.reverse! if opts[:reverse]
      inputs.select!{ |i| i.fn_out }
      inputs.each do |i|
        upload i
      rescue => e
        input_error e, i
      end
    end

    msg.resp
  end

  def input_error e, i
    i&.except! :info
    report_error msg, e, context: i.inspect
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

    fn_io   = Faraday::UploadIO.new fn_out, type.mime
    ret_msg = i.ret_msg = {
      type:        type.name,
      type.name => fn_io,
      duration:    durat,
      width:       vstrea&.width,
      height:      vstrea&.height,
      title:       info.title,
      performer:   info.uploader,
      thumb:       thumb,
      supports_streaming: true,
    }
    send_message msg, caption, **ret_msg
  end

  def msg_caption i
    return '' if opts.nocaption
    text = ''
    if opts.caption or i.type == Zipper::Types.video
      text  = "_#{me i.info.title}_"
      text << "\nby #{me i.info.uploader}" if i.info.uploader
    end
    text << "\n\n_#{me i.info.description.strip}_" if opts.description and i.info.description.strip.presence
    text << "\n\n#{me i.url}" if i.url
    text
  end

end

