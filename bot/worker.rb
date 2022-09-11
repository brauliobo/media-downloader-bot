class Bot::Worker

  attr_reader :bot
  attr_reader :msg
  attr_reader :dir

  attr_accessor :resp

  delegate_missing_to :bot

  def initialize bot, msg
    @bot = bot
    @msg = msg
  end

  def process
    Dir.mktmpdir "mdb-" do |dir|
      @dir   = dir
      procs  = []
      inputs = []

      @resp = send_message msg, me('Downloading...')
      if msg.audio.present? or msg.video.present?
        procs << Bot::FileProcessor.new(bot, msg, dir)
      else
        procs = msg.text.split("\n").flat_map do |l|
          Bot::UrlProcessor.new bot, msg, dir, l
        end
      end

      procs.each.with_index.peach do |p, i|
        inputs[i] = p.download
      end
      inputs.flatten!
      inputs.compact!
      return @resp = nil if inputs.blank?

      edit_message msg, resp.result.message_id, text: (resp.text << me("\nConverting..."))
      inputs.api_peach do |i|
        p = Bot::Processor.new bot, msg, dir
        p.handle_input i
      rescue => e
        input_error e, i
      end

      opts = inputs.first.opts

      inputs.select!{ |i| i.fn_out }
      inputs.sort_by!{ |i| i.info.title } if opts.sort
      inputs.reverse! if opts.reverse

      edit_message msg, resp.result.message_id, text: (resp.text << me("\nSending..."))
      inputs.each do |i|
        upload i
      rescue => e
        input_error e, i
      end
    end

    @resp
  end

  def input_error e, i
    i&.except! :info
    report_error msg, e, context: i.inspect
  end

  def upload input
    fn_out = input.fn_out
    type   = input.type
    info   = input.info
    durat  = input.durat
    opts   = input.opts

    caption = msg_caption info, type, input
    require'pry';binding.pry
    return send_message msg, caption if opts.simulate

    oprobe = Bot::Prober.for fn_out
    vstrea = oprobe&.streams&.find{ |s| s.codec_type == 'video' }

    fn_io   = Faraday::UploadIO.new fn_out, type.mime
    ret_msg = input.ret_msg = {
      type:        type.name,
      type.name => fn_io,
      duration:    durat,
      width:       vstrea&.width,
      height:      vstrea&.height,
      title:       info.title,
      performer:   info.uploader,
      thumb:       thumb(info, dir),
      supports_streaming: true,
    }
    send_message msg, caption, ret_msg
  end

  def msg_caption info, type, input
    text = ''
    if opts.caption or type == Types.video
      text  = "_#{me info.title}_"
      text << "\nby #{me info.uploader}" if info.uploader
    end
    text << "\n\n_#{me info.description.strip}_" if opts.description and info.description.strip.presence
    text << "\n\n#{me input.url}" if input.url
    text
  end

  def thumb info, dir
    return if info.thumbnails.blank?

    url    = info.thumbnails.first.url
    return unless url
    im_in  = "#{dir}/img"
    im_out = "#{dir}/#{info._filename}-thumb.jpg"

    File.write im_in, http.get(url).body
    system "convert #{im_in} -resize x320 -define jpeg:extent=190kb #{im_out}"

    Faraday::UploadIO.new im_out, 'image/jpeg'

  rescue => e # continue on errors
    report_error msg, e
    nil
  end

  def http
    Mechanize.new
  end

end

