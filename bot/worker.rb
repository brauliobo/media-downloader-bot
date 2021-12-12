require 'taglib'

class Bot::Worker

  include Zipper

  VID_DURATION_THLD = 35
  AUD_DURATION_THLD = 80

  VID_TOO_LONG   = "\nQuality is compromised as the video is too long to fit the #{SIZE_MB_LIMIT}MB upload limit on Telegram Bots"
  AUD_TOO_LONG   = "\nQuality is compromised as the audio is too long to fit the #{SIZE_MB_LIMIT}MB upload limit on Telegram Bots"

  VID_TOO_BIG = "\nVideo over #{SIZE_MB_LIMIT}MB Telegram Bot's limit, converting to audio..."
  TOO_BIG     = "\nFile over #{SIZE_MB_LIMIT}MB Telegram Bot's limit"

  # missing mimes
  Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'
  Rack::Mime::MIME_TYPES['.mkv']  = 'video/x-matroska'

  attr_reader :bot
  attr_reader :msg, :args, :opts
  attr_reader :url
  attr_reader :dir

  attr_accessor :resp

  delegate_missing_to :bot

  def initialize bot, msg
    @bot  = bot
    @msg  = msg
    @args = msg.text.to_s.split(/\s+/)
    @opts = args.each.with_object SymMash.new do |a, h|
      k,v = a.split '=', 2
      h[k] = v || 1
    end
  end

  def process
    Dir.mktmpdir "mdb-" do |dir|
      @dir   = dir
      inputs = []

      if msg.text.present?
        @url  = URI.parse args.shift
        return unless url.is_a? URI::HTTP
        @resp = send_message msg, me('Downloading...')

        inputs  = url_download url, opts
        break if inputs.blank?

      elsif msg.audio.present? or msg.video.present?
        @resp = send_message msg, me('Downloading...')
        inputs << file_download(msg)
      end

      inputs.api_peach do |i|
        handle_input i, opts
      rescue => e
        input_error e, i
      end

      inputs.select!{ |i| i.fn_out }
      inputs.reverse! if opts.reverse

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

  def handle_input input, opts
    fn_in  = input.fn_in
    info   = input.info
    iprobe = probe_for fn_in
    vstrea = iprobe&.streams&.find{ |s| s.codec_type == 'video' }
    durat  = iprobe.format.duration.to_i

    mtype  = Rack::Mime.mime_type File.extname fn_in
    type   = if mtype.index 'video' then Types.video elsif mtype.index 'audio' then Types.audio end
    type   = Types.audio if opts.audio
    unless type
      edit_message msg, resp.result.message_id, text: me("Unknown type for #{fn_in}")
      return
    end

    # FIXME: specify different levels depending on length
    if type == Types.video and durat > VID_DURATION_THLD.minutes.to_i
      opts.width = 480
      edit_message msg, resp.result.message_id, text: (resp.text << me(VID_TOO_LONG))
    end
    if type == Types.audio and durat > AUD_DURATION_THLD.minutes.to_i
      opts.bitrate = 64
      edit_message msg, resp.result.message_id, text: (resp.text << me(AUD_TOO_LONG))
    end

    if skip_convert? type, iprobe, opts
      fn_out = fn_in
    else
      fn_out = convert info, fn_in, type: type, probe: iprobe
      return unless fn_out
    end

    # check telegram bot's upload limit
    mbsize = File.size(fn_out) / 2**20
    if type == Types.video and mbsize >= SIZE_MB_LIMIT
      edit_message msg, resp.result.message_id, text: (resp.text << me(VID_TOO_BIG))
      type   = Types.audio
      fn_out = convert info, fn_in, type: type, probe: iprobe
      mbsize = File.size(fn_out) / 2**20
    end
    # still too big as audio...
    if mbsize >= SIZE_MB_LIMIT
      edit_message msg, resp.result.message_id, text: (resp.text << me(TOO_BIG))
      return
    end

    tag fn_out, info

    input.fn_out = fn_out
    input.durat  = durat
    input.type   = type
    input
  end

  def upload input
    fn_out = input.fn_out
    type   = input.type
    info   = input.info
    durat  = input.durat

    text = ''
    if opts.caption or type == Types.video
      text  = "_#{me info.title}_"
      text << "\nby #{me info.uploader}" if info.uploader
    end
    text << "\n\n_#{me info.description}_" if opts.description and info.description
    text << "\n\n#{me input.url}" if input.url

    oprobe = probe_for fn_out
    vstrea = oprobe&.streams&.find{ |s| s.codec_type == 'video' }

    edit_message msg, resp.result.message_id, text: (resp.text << me("\nSending..."))
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
    send_message msg, text, ret_msg
  end

  def tag fn, info
    TagLib::FileRef.open fn do |f|
      return if f&.tag.nil?
      f.tag.title  = info.title
      f.tag.artist = info.uploader
      f.save
    end
  end

  DOWN_BIN   = "yt-dlp"
  DOWN_CMD   = "#{DOWN_BIN} --write-info-json --no-clean-infojson '%{url}'"
  USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36'
  DOWN_OPTS = %i[referer]

  def url_download url, opts
    cmd  = DOWN_CMD % {url: url.to_s}
    cmd << " --cache-dir #{dir}"
    cmd << " -o 'input-%(playlist_index)s.%(ext)s'"
    cmd << ' -x' if opts.audio
    opts.slice(*DOWN_OPTS).each do |k,v|
      v.gsub! "'", "\'"
      cmd << " --#{k} '#{v}'"
    end
    # user-agent can slowdown on youtube
    #cmd << " --user-agent '#{USER_AGENT}'" unless url.host.index 'facebook'

    _o, e, st = Open3.capture3 cmd, chdir: dir
    if st != 0
      edit_message msg, resp.result.message_id, text: "Download failed:\n<pre>#{he e}</pre>", parse_mode: 'HTML'
      return
    end

    infos  = Dir.glob("#{dir}/*.info.json").sort_by{ |f| File.mtime f }
    infos.map! do |infof|
      info = SymMash.new JSON.parse File.read infof
      File.unlink infof # for the next Dir.glob to work properly

      next unless info._filename # playlist info
      info
    end.compact!
    mult   = infos.size > 1

    infos.map.with_index do |info, i|
      fn    = info._filename
      # info._filename extension isn't accurate
      fn_in = Dir.glob("#{dir}/#{File.basename fn, File.extname(fn)}*").first

      # number files
      info.title = "#{"%02d" % (i+1)} #{info.title}" if mult and opts.number

      url = info.url = if mult then info.webpage_url else url.to_s end
      url = Bot::UrlShortner.shortify(info) || url
      SymMash.new(
        fn_in: fn_in,
        url:   url,
        info:  info,
      )
    end.compact
  end

  def file_download msg
    info   = msg.video || msg.audio
    file   = SymMash.new api.get_file file_id: info.file_id
    fn_in  = file.result.file_path
    page   = http.get "https://api.telegram.org/file/bot#{ENV['TOKEN']}/#{fn_in}"

    fn_out = "#{dir}/input.#{File.extname fn_in}"
    File.write fn_out, page.body

    SymMash.new(
      fn_in: fn_out,
      info: {
        title: info.file_name,
      },
    )
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

  def skip_convert? type, probe, opts
    stream = probe.streams.first
    return true if type.name == :audio and stream.codec_name == 'aac' and stream.bit_rate.to_i/1000 < Types.audio.opts.bitrate
    false
  end

  def convert info, fn_in, type:, probe:
    fn_out  = info.title.dup
    fn_out << " by #{info.uploader}" if info.uploader
    fn_out << ".#{type.ext}"
    fn_out.gsub! '"', '' # Telegram doesn't accept "
    fn_out.gsub! '/', ', ' # not escaped by shellwords
    fn_out  = "#{dir}/#{fn_out}"

    edit_message msg, resp.result.message_id, text: (resp.text << me("\nConverting..."))
    o, e, st = send "zip_#{type.name}", fn_in, fn_out, opts: opts, probe: probe
    if st != 0
      edit_message msg, resp.result.message_id, text: (resp.text << me("\nConvert failed: #{o}\n#{e}"))
      return
    end

    fn_out
  end

  PROBE_CMD = "ffprobe -v quiet -print_format json -show_format -show_streams %{file}"

  def probe_for file
    probe = `#{PROBE_CMD % {file: Shellwords.escape(file)}}`
    probe = JSON.parse probe if probe.present?
    probe = SymMash.new probe
  end

  def http
    Mechanize.new
  end

end

