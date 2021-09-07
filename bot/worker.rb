class Bot::Worker

  DURATION_LIMIT = 20
  SIZE_MB_LIMIT  = 50

  MSG_TOO_LONG   = "\nVideo too long for #{SIZE_MB_LIMIT}MB Telegram Bot's limit, converting to audio..."
  MSG_VD_TOO_BIG = "\nVideo over #{SIZE_MB_LIMIT}MB Telegram Bot's limit, converting to audio..."
  MSG_TOO_BIG    = "\nFile over #{SIZE_MB_LIMIT}MB Telegram Bot's limit"

  # missing mimes
  Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'

  include Zipper

  attr_reader :bot
  attr_reader :msg, :args, :opts
  attr_reader :url
  attr_reader :resp
  attr_reader :dir

  delegate_missing_to :bot

  def initialize bot, msg
    @bot  = bot
    @msg  = msg
    @args = msg.text.to_s.split(/\s+/)
    @opts = args.each.with_object(SymMash.new){ |a, h| h[a] = 1 }
  end

  def process
    Dir.mktmpdir "mdb-" do |dir|
      @dir   = dir
      inputs = []

      if msg.text.present?
        @url  = args.shift
        return unless URI.parse(url).is_a? URI::HTTP
        @resp = send_message msg, "Downloading..."

        inputs  = youtube_dl url, opts
        break if inputs.blank?

      elsif msg.audio.present? or msg.video.present?
        @resp = send_message msg, "Downloading..."
        inputs << file_download(msg)
      end

      inputs.each do |i|
        handle_input i, opts
      end
    end

    @resp
  end

  def handle_input input, opts
    fn_in  = input.fn_in
    info   = input.info
    probe  = probe_for fn_in
    vstrea = probe&.streams&.find{ |s| s.codec_type == 'video' }
    durat  = probe.format.duration.to_i

    mtype  = Rack::Mime.mime_type File.extname fn_in
    type   = if mtype.index 'video' then Types.video elsif mtype.index 'audio' then Types.audio end
    type   = Types.audio if opts.audio
    # current video compression is about 2mb per min
    if type == Types.video and (durat / 60).seconds > DURATION_LIMIT.minutes
      edit_message msg, resp.result.message_id, text: (resp.text << MSG_TOO_LONG)
      type = Types.audio
    end
    unless type
      edit_message msg, resp.result.message_id, text: "Unknown type for #{fn_in}"
      return
    end

    if skip_convert? type, probe, opts
      fn_out = fn_in
    else
      fn_out = convert info, fn_in, type
    end
    mbsize = File.size(fn_out) / 2**20

    # duration check above can fail, fallback to size check
    if type == Types.video and mbsize >= SIZE_MB_LIMIT
      edit_message msg, resp.result.message_id, text: (resp.text << MSG_VD_TOO_BIG)
      type   = Types.audio
      fn_out = convert info, fn_in, type
      mbsize = File.size(fn_out) / 2**20
    end
    # still too big as audio...
    if mbsize >= SIZE_MB_LIMIT
      edit_message msg, resp.result.message_id, text: (resp.text << MSG_TOO_BIG)
      return
    end

    unless opts.nocaption
      text  = "_#{e info.title}_"
      text << "\nby #{e info.uploader}" if info.uploader
      text << "\n\n#{e input.url}" if input.url
    end

    edit_message msg, resp.result.message_id, text: (resp.text << "\nSending...")
    fn_io = Faraday::UploadIO.new fn_out, mtype
    send_message(msg, text,
      type:        type.name,
      type.name => fn_io,
      duration:    durat,
      width:       vstrea&.width,
      height:      vstrea&.height,
      title:       info.title,
      thumb:       thumb(info, dir),
      supports_streaming: true,
    )
  end

  DOWN_CMD  = "youtube-dl -4 --user-agent 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36' -f worst --write-info-json '%{url}'"

  def youtube_dl url, opts
    cmd  = DOWN_CMD % {url: url}
    cmd << " -o 'input-%(playlist_index)s.%(ext)s'"
    cmd << ' -x' if opts.audio
    _o, e, st = Open3.capture3 cmd, chdir: dir
    if st != 0
      edit_message msg, resp.result.message_id, text: "Download failed:\n<pre>#{he e}</pre>", parse_mode: 'HTML'
      return
    end

    infos   = Dir.glob("#{dir}/*.info.json").sort_by{ |f| File.mtime f }
    mult    = infos.size > 1
    infos.map.with_index do |info, i|
      info  = SymMash.new JSON.parse File.read info
      # glob instead as info._filename comes with the wrong extension when -x is used
      fn_in = Dir.glob("#{dir}/#{File.basename info._filename, File.extname(info._filename)}*").first

      # number files
      info.title = "#{"%02d" % (i+1)} #{info.title}" if mult and opts.nocaption

      SymMash.new(
        fn_in: fn_in,
        info:  info,
        url:   if mult then info.webpage_url else url end,
      )
    end
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
    url    = info.thumbnails&.last&.url
    return unless url
    im_in  = "#{dir}/img"
    im_out = "#{dir}/out.jpg"

    File.write im_in, http.get(url).body
    system "convert #{im_in} -resize x320 -define jpeg:extent=190kb #{im_out}"

    Faraday::UploadIO.new im_out, 'image/jpeg'
  end

  def skip_convert? type, probe, opts
    stream = probe.streams.first
    return true if type.name == :audio and stream.codec_name == 'aac' and stream.bit_rate.to_i/1000 < Types.audio.opts.bitrate
    false
  end

  def convert info, fn_in, type
    fn_out  = "#{dir}/#{info.title} by .#{type.ext}"
    fn_out += "by #{info.uploader}" if info.uploader
    fn_out += ".#{type.ext}"
    edit_message msg, resp.result.message_id, text: (resp.text << "\nConverting...")
    send "zip_#{type.name}", fn_in, fn_out
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

