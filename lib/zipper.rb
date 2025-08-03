require 'tempfile'
require 'fileutils'
require_relative 'subtitler/ass'

class Zipper

  class_attribute :size_mb_limit

  VID_WIDTH    = 720
  VID_PERCENT  = 0.99

  TIME_REGEX   = /(?:\d?\d:)(?:\d?\d:)\d\d/

  # Constants removed; quality defaults are set dynamically per instance.
  VFR_OPTS    = '-vsync vfr'
  VF_SCALE_M2 = "scale=%{width}:trunc(ow/a/2)*2".freeze
  VF_SCALE_M8 = "scale=%{width}:trunc(ow/a/8)*8".freeze

  META_MARK  = '-metadata downloaded_with=t.me/media_downloader_2bot'.freeze
  META_OPTS  = '-map_metadata 0 -id3v2_version 3 -movflags use_metadata_tags -write_id3v1 1'
  META_OPTS << " #{META_MARK} %{metadata}"

  AUDIO_POST_OPTS  = ''
  AUDIO_POST_OPTS << " #{META_OPTS}" unless ENV['SKIP_META']
  VIDEO_POST_OPTS  = '-movflags +faststart'
  VIDEO_POST_OPTS << " #{META_OPTS}" unless ENV['SKIP_META']
  VIDEO_POST_OPTS.freeze

  FDK_AAC = `ffmpeg -encoders 2>/dev/null | grep fdk_aac`.present?

  AUDIO_ENC = SymMash.new(
    opus: {
      percent: 0.95,
      encode:  '-ac 2 -c:a libopus -b:a %{abrate}k'.freeze,
    },
    aac:  {
      percent: 0.98,
      # aac_he_v2 doesn't work with instagram
      encode: if FDK_AAC
              then '-c:a libfdk_aac -profile:a aac_he -b:a %{abrate}k'.freeze
              else '-c:a aac -b:a %{abrate}k'.freeze end
    },
    mp3:  {
      percent: 0.99,
      encode:  '-c:a libmp3lame -abr 1 -b:a %{abrate}k'.freeze,
    },
  )

  THREADS = ENV['THREADS']&.to_i || 16
  FFMPEG  = "ffmpeg -y -threads #{THREADS} -loglevel error"

  # General templates with placeholder keys. Substitutions can be blank strings.
  VIDEO_CMD_TPL = (
    "#{FFMPEG} -i %{infile} %{iopts} -filter_complex \"%{fgraph}\" " \
    "#{VFR_OPTS} %{maps} %{vflags} %{acodec} %{vpost} %{oopts} %{outfile}"
  ).freeze

  AUDIO_CMD_TPL = (
    "#{FFMPEG} -vn -i %{infile} %{iopts} %{acodec} %{apost} %{oopts} %{outfile}"
  ).freeze

  FG_SEP      = ','.freeze
  INPUT_LINE  = "-i %{infile} %{iopts} -filter_complex \"#{VF_SCALE_M2}#{FG_SEP}%{fgraph}\" #{VFR_OPTS} %{maps}"
  INPUT8_LINE = "-i %{infile} %{iopts} -filter_complex \"#{VF_SCALE_M8}#{FG_SEP}%{fgraph}\" #{VFR_OPTS} %{maps}"

  Types = SymMash.new(
    video: {
      name:     :video,
      default:  :h264,
      ldefault: :h265,

      h264: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, quality: 25, abrate: 64, acodec: :aac, percent: VID_PERCENT}, # quality adjusted dynamically
        szopts_cpu:  "-maxrate:v %{maxrate} -bufsize %{bufsize}",
        szopts_cuda: '', # CUDA can't handle maxrate with setpts
        codec_cpu:  'libx264',
        codec_cuda: 'h264_nvenc',
        qflag_cpu:  '-crf',
        qflag_cuda: '-crf'
      },

      # - SVT-HEVC is discontinued
      # - Performance with ultrafast preset is close to SVT-AV1
      # - Even with much lower CRF, H265 (30 - 21mb) have much lower file size compared to SVT-AV1 (50 - 28mb),
      # which seems to handle better lower resolution and bitrates
      h265: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, quality: 25, abrate: 64, acodec: :aac, percent: VID_PERCENT}, # quality adjusted dynamically
        szopts_cpu:  "-maxrate:v %{maxrate}",
        szopts_cuda: '-rc:v vbr',
        codec_cpu:  'libx265',
        codec_cuda: 'hevc_nvenc',
        qflag_cpu:  '-crf',
        qflag_cuda: '-cq'
      },

      # - MBR reduces quality too much, https://gitlab.com/AOMediaCodec/SVT-AV1/-/issues/2065
      # - Not compatible to upload on Whatsapp Web
      av1: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, quality: 50, abrate: 64, acodec: :opus, percent: VID_PERCENT},
        szopts: '',
        codec_cpu:  'libsvtav1',
        codec_cuda: 'av1_nvenc',
        qflag_cpu:  '-crf',
        qflag_cuda: '-cq',
        extra_cuda: '-preset p6'
      },

      # VP9 doesn't seem to respect low bitrates:
      # - it can't control file size in quality mode,
      # - target bitrate mode also not ensuring desired bitrate
      # - SVT-VP9 is discontinued
      vp9: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, vbrate: 835, abrate: 64, acodec: :aac, percent: 0.97},
        szopts: "-rc vbr -b:v %{maxrate}",
        codec_cpu:  'libsvt_vp9',
        qflag_cpu:  '',
      },

    },

    audio: {
      name:    :audio,
      default: :opus,

      opus: {
        ext:    :opus,
        mime:   'audio/aac',
        opts:   {bitrate: 96, percent: AUDIO_ENC.opus.percent},
        encode: AUDIO_ENC.opus.encode,
      },

      aac: {
        ext:    :m4a,
        mime:   'audio/aac',
        opts:   {bitrate: 96, percent: AUDIO_ENC.aac.percent},
        encode: AUDIO_ENC.aac.encode,
      },

      mp3: {
        ext:    :mp3,
        mime:   'audio/mp3',
        opts:   {bitrate: 128, percent: AUDIO_ENC.mp3.percent},
        encode: AUDIO_ENC.mp3.encode,
      },
    },
  )

  def self.max_audio_duration br
    1000 * Zipper.size_mb_limit / (br.to_i / 8) / 60
  end

  # Dynamic helpers that reevaluate the thresholds at runtime
  def self.vid_duration_thld
    return Float::INFINITY unless size_mb_limit
    # Baseline: 20 minutes when the limit is 50 MB (Telegram). Scale linearly with higher limits.
    (size_mb_limit * 20.0 / 50).ceil
  end

  def self.aud_duration_thld
    size_mb_limit ? max_audio_duration(Types.audio.opus.opts.bitrate) : Float::INFINITY
  end

  # reduce width for every minutes interval exceeding vid_duration_thld
  VID_WIDTH_REDUC = SymMash.new width: 80, minutes: 8
  AUD_BRATE_REDUC = SymMash.new brate:  8, minutes: 8

  def self.zip_video *args, **params
    self.new(*args, **params).zip_video
  end
  def self.zip_audio *args, **params
    self.new(*args, **params).zip_audio
  end

  def self.concat_audio inputs, outfile, stl: nil
    return FileUtils.cp inputs.first, outfile if inputs.size == 1

    Dir.mktmpdir do |dir|
      listfile = File.join(dir, 'concat.txt')
      File.write listfile, inputs.map { |p| "file '#{p}'" }.join("\n")

      cmd = [
        'ffmpeg', '-y', '-f', 'concat', '-safe', '0', '-i', Sh.escape(listfile),
        '-c', 'copy', Sh.escape(outfile)
      ].join(' ')

      _, _, status = Sh.run cmd
      raise 'FFmpeg concat failed' unless status.success?
    end

    outfile
  end

  def self.choose_format type_hash, opts, durat
    fmt   = opts && opts.format
    fmt ||= if durat && durat >= 10.minutes then type_hash[:ldefault] else type_hash[:default] end
    fmt   = :aac if Zipper.size_mb_limit && fmt == :opus && durat && durat <= 122 # telegram consider small opus as voice
    fmt   = type_hash[fmt]
    fmt
  end

  def self.extract_vtt infile, language
    self.new(infile, nil, opts: SymMash.new(format: {})).extract_vtt language
  end

  attr_reader :infile, :outfile, :probe, :stl
  attr_reader :info
  attr_reader :iopts, :oopts, :dopts, :opts
  attr_reader :fgraph, :maps
  attr_reader :duration
  attr_reader :type

  def initialize infile, outfile, info: nil, probe: nil, stl: nil, opts: SymMash.new
    @infile  = infile
    @outfile = outfile
    @info    = info
    @probe   = probe ||= Prober.for infile
    @stl     = stl

    @iopts = ''; @oopts = ''; @dopts = opts.format.opts
    @opts = opts
    @opts.custom_width = true if opts.width
    @opts.reverse_merge! dopts

    @fgraph = []
    @fgraph << opts.vf if opts.vf.present?

    @maps = []

    opts.speed   = opts.speed&.to_f || 1
    opts.width   = opts.width&.to_i
    opts.quality = opts.quality&.to_i if opts.quality
    opts.abrate  = opts.abrate&.to_i
    # Use the instance variable to avoid referencing the (possibly nil) local parameter.
    @duration    = probe.format.duration.to_f / opts.speed
    opts.cuda    = if opts.nocuda then false elsif opts.cuda then true else !!ENV['CUDA'] end

    case opts.format
    when Types.video.h264 then opts.quality = if opts.cuda then 33 else 25 end
    when Types.video.h265 then opts.quality = if opts.cuda then 33 else 25 end
    else opts.quality ||= opts.format.opts.quality
    end
  end

  # Detect the current format key (e.g. :h264, :aac).
  def format_name
    @format_name ||= begin
      v = opts.format
      case v
      when Types.video.h264 then :h264
      when Types.video.h265 then :h265
      when Types.video.av1  then :av1
      when Types.video.vp9  then :vp9
      when Types.audio.opus then :opus
      when Types.audio.aac  then :aac
      when Types.audio.mp3  then :mp3
      else :unknown end
    end
  end

  # szopts template depending on codec and CUDA availability.
  def video_sz_template
    spec = opts.format
    if spec.respond_to?(:szopts_cpu) || spec.respond_to?(:szopts_cuda)
      if opts.cuda then spec.szopts_cuda else spec.szopts_cpu end
    else
      spec.szopts || ''
    end
  end

  def video?; @type == :video; end
  def audio?; @type == :audio; end

  def zip_video
    @type = :video

    # Ensure the NVENC encoder receives frames in a supported pixel format
    # add it early so it comes right after the scale* filter and before any
    # other dynamically-added filters, avoiding a dangling comma when no
    # other filters are present.
    fgraph << 'format=yuv420p' if opts.cuda && !fgraph.include?('format=yuv420p')
    check_width
    reduce_framerate
    limit_framerate
    apply_audio_rate
    apply_audio_channels

    apply_subtitle
    apply_speed
    apply_cut
    szopts = apply_video_size_limits

    aenc        = AUDIO_ENC[opts.acodec&.to_sym] || AUDIO_ENC.opus
    opts.abrate = (aenc.percent * opts.abrate).round if size_mb_limit
    acodec      = aenc.encode % {abrate: opts.abrate}

    # Build filter graph with scaling first.
    scale_expr   = (format_name == :vp9 ? VF_SCALE_M8 : VF_SCALE_M2) % {width: opts.width}
    full_fgraph  = ([scale_expr] + fgraph).join(FG_SEP)
    maps_str     = maps.map { |m| "-map #{m}" }.join(' ')

    # Video encoder specific flags defined by format spec.
    preset        = opts.cuda ? 'medium' : 'fast'
    spec         = opts.format

    vcodec       = opts.cuda ? (spec.codec_cuda || spec.codec_cpu) : spec.codec_cpu
    qflag        = opts.cuda ? (spec.qflag_cuda || spec.qflag_cpu) : spec.qflag_cpu
    extra        = opts.cuda ? (spec.extra_cuda || '')            : (spec.extra_cpu || '')

    v_flags_parts = ["-c:v #{vcodec}"]
    v_flags_parts << "#{qflag} #{opts.quality}" if qflag.present? && opts.quality
    v_flags_parts << "-preset #{preset}"
    v_flags_parts << extra if extra.present?
    v_flags_parts << szopts if szopts.present?

    v_flags = v_flags_parts.join(' ')

    video_post_opts = VIDEO_POST_OPTS % {metadata: metadata_args}

    cmd_params = {
      infile:  Sh.escape(infile),
      iopts:   iopts,
      fgraph:  full_fgraph,
      maps:    maps_str,
      vflags:  v_flags,
      acodec:  acodec,
      vpost:   video_post_opts,
      oopts:   oopts,
      outfile: Sh.escape(outfile),
    }

    cmd = VIDEO_CMD_TPL % cmd_params
    cmd.squeeze!(" ")
    Sh.run cmd
  end

  def zip_audio
    @type = :audio

    apply_audio_rate
    apply_audio_channels

    apply_speed
    apply_audio_size_limit
    apply_cut

    # Encoder template defined by format spec
    acodec_tmpl = opts.format.encode
    acodec      = acodec_tmpl % {abrate: opts.bitrate}

    audio_post_opts = AUDIO_POST_OPTS % {metadata: metadata_args}

    cmd_params = {
      infile:  Sh.escape(infile),
      iopts:   iopts,
      acodec:  acodec,
      apost:   audio_post_opts,
      oopts:   oopts,
      outfile: Sh.escape(outfile),
    }

    cmd = AUDIO_CMD_TPL % cmd_params
    cmd.squeeze!(" ")
    Sh.run cmd
  end

  def subtitle_to_vtt body, ext
    File.write "sub.#{ext}", body
    vtt, _, _ = Sh.run <<-EOC
ffmpeg -i sub.#{ext} -c:s webvtt -f webvtt -
    EOC
    vtt
  end

  def extract_vtt lang_or_index
    vttfile = "#{File.basename infile, File.extname(infile)}.vtt"

    subs  = probe.streams.select{ |s| s.codec_type == 'subtitle' }
    index = if lang_or_index.is_a? Numeric then lang_or_index else subs.index{ |s| s.tags.language == lang_or_index } end

    vtt, _, _ = Sh.run <<-EOC
ffmpeg -loglevel error -i #{Sh.escape infile} -map 0:s:#{index} -c:s webvtt -f webvtt -
    EOC
    vtt
  end

  def self.audio_to_wav path
    wpath = 'audio.wav'

    cmd = ['ffmpeg', '-i', Sh.escape(path), '-y', Sh.escape(wpath)].join(' ')
    _, _, st = Sh.run cmd
    raise 'ffmpeg failed' unless st.success?

    wpath
  end

  # Public helper: prepare subtitles and return [vtt, lang, verbose_json]
  def self.prepare_subtitle infile, info:, probe:, stl:, opts:
    new(infile, nil, info: info, probe: probe, stl: stl, opts: opts).prepare_subtitle
  end

  # Prepare subtitles (download, transcribe, translate) and return
  # [vtt_string, language_iso, verbose_json_or_nil]
  def prepare_subtitle
    vtt = nil; lng = nil; tsp = nil

    vtt,lng = fetch_subtitle unless opts.gensubs

    if vtt.nil?
      stl&.update 'transcribing'
      res = Subtitler.transcribe infile
      tsp,lng = res.output, res.lang
      vtt = Subtitler.vtt_convert tsp, word_tags: !opts.nowords
      info.language ||= lng
    end

    if opts.lang && lng && opts.lang.to_s != lng.to_s
      stl&.update 'translating'
      if tsp
        tsp = Subtitler.translate tsp, from: lng, to: opts.lang
        vtt = Subtitler.vtt_convert tsp, word_tags: !opts.nowords
      else
        vtt = Translator.translate_vtt vtt, from: lng, to: opts.lang
      end
      lng = opts.lang
    end

    [vtt, lng, tsp]
  end

  protected

  def reduce_framerate
    return unless opts.nompdecimate
    fgraph << 'mpdecimate'
  end

  def limit_framerate
    # FIXME: conflict with MP4 vsync vfr
    iopts << " -r #{opts.maxfr.to_i}" if opts.maxfr
  end

  def apply_audio_rate
    return unless rate = opts.freq&.to_i || opts.ar&.to_i
    iopts << " -ar #{rate}"
  end

  def apply_audio_channels
    # Workaround for "Channel layout change is not supported"
    # https://www.atlas-informatik.ch/multimediaXpert/Convert.en.html
    iopts << " -ac #{opts.ac.to_i}" if opts.ac
  end

  def apply_audio_size_limit
    return unless size_mb_limit

    opts.bitrate = (opts.percent * 8*size_mb_limit*1000).to_f / duration if self.class.max_audio_duration(opts.bitrate) < duration / 60
  end

  def apply_video_size_limits
    return unless size_mb_limit
    return if opts.custom_width

    minutes  = (duration / 60).ceil
    vthld    = self.class.vid_duration_thld

    # reduce resolution
    if minutes > vthld and opts.width > dopts.width/3
      reduc,intv  = VID_WIDTH_REDUC.values_at :width, :minutes
      opts.width -= reduc * ((minutes - vthld).to_f / intv).ceil
      opts.width  = dopts.width/3 if opts.width < dopts.width/3
      opts.width -= 1 if opts.width % 2 == 1
    end
    # reduce audio bitrate
    if minutes > vthld and opts.abrate > dopts.abrate/2
      reduc,intv   = AUD_BRATE_REDUC.values_at :brate, :minutes
      opts.abrate -= reduc * ((minutes - vthld).to_f / intv).ceil
      opts.abrate  = dopts.abrate/2 if opts.abrate < dopts.abrate/2
    end

    audsize  = (duration * opts.abrate.to_f/8) / 1000
    vidsize  = (size_mb_limit - audsize).to_i
    bufsize  = "#{vidsize}M"

    maxrate  = (8*(opts.percent * vidsize * 1000) / duration).to_i
    maxrate  = opts.vbrate if opts.vbrate and maxrate > opts.vbrate
    maxrate  = "#{maxrate}k"

    video_sz_template % {maxrate:, bufsize:}
  end

  def apply_speed
    return if opts.speed == 1

    fgraph << "setpts=PTS/#{opts.speed}" if video?
    #iopts  << " -t #{duration}" # attached subtitle mess with the length of the video
    oopts  << " -af atempo=#{opts.speed}"
  end

  def check_width
    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
    if opts.vf&.index 'transpose'
    elsif vstrea.width < vstrea.height # portrait image
      opts.width /= 2
    end

    # lower resolution
    opts.width = vstrea.width if vstrea.width < opts.width
  end

  def fetch_subtitle
    # scraped subtitles
    if (subs = info&.subtitles).present?
      cads = [opts.lang, :en, subs.keys.first]
      lng,lsub =  cads.each.with_object([]){ |s, r| break r = [s, subs[s]] if subs.key? s }
      return if lng.blank?
      lsub = lsub.find{ |s| s.ext == 'vtt' } || lsubs[0]
      sub  = http.get(lsub.url).body
      vtt  = subtitle_to_vtt sub, lsub.ext

    # embedded subtitles
    elsif (esubs = probe.streams.select{ |s| s.codec_type == 'subtitle' }).present?
      esubs.each{ |s| s.lang = ISO_639.find_by_code(s.tags.language).alpha2 }
      index = esubs.index{ |s| opts.lang.in? [s.lang, s.tags.language, s.tags.title] }
      return unless index
      vtt   = extract_vtt index
      lng   = esubs[index].lang
      opts.lang = lng
    end

    [vtt, lng]
  end

  # Generate an SRT file from the given media and return its path
  def self.generate_srt infile, dir:, info:, probe:, stl:, opts:
    opts ||= SymMash.new
    opts.format ||= Zipper::Types.audio.opus unless opts.respond_to?(:format) && opts.format
    opts.audio ||= 1 # audio-only download is enough for transcription

    vtt,lng,tsp = prepare_subtitle(infile, info: info, probe: probe, stl: stl, opts: opts)

    require_relative 'output'
    srt_path = Output.filename(info, dir: dir, ext: 'srt')
    if tsp
      srt_content = Subtitler.srt_convert(tsp, word_tags: !opts.nowords)
    else
      vtt_path = File.join(dir, 'sub.vtt')
      File.write vtt_path, vtt
      srt_content, _, status = Sh.run "ffmpeg -loglevel error -y -i #{Sh.escape vtt_path} -f srt -"
      raise 'srt conversion failed' unless status.success?
    end



    File.write srt_path, srt_content
    srt_path
  end

  def apply_subtitle
    return if !opts.lang && !opts.subs && !opts.onlysrt

    vtt,lng,_tsp = prepare_subtitle
    stl&.update 'transcoding'

    # generate ASS subtitle directly (scales font automatically for portrait videos)
    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
    is_portrait = vstrea.width < vstrea.height
    ass_content = Subtitler::Ass.from_vtt vtt, portrait: is_portrait, mode: if opts.nowords then :plain else :instagram end

    assp = 'sub.ass'
    File.write assp, ass_content
    fgraph << "ass=#{assp}"

    # Write VTT for embedding
    subp = 'sub.vtt'
    File.write subp, vtt
    iopts << " -i #{subp}"
    # embed subtitle track if speed not changed (timestamps stay aligned)
    oopts << " -c:s mov_text -metadata:s:s:0 language=#{lng} -metadata:s:s:0 title=#{lng}" if opts.speed == 1
  end

  def metadata_args
    (opts.metadata || {}).map{ |k,v| "-metadata #{Sh.escape k}=#{Sh.escape v}" }.join ' '
  end

  def apply_cut
    iopts << " -ss #{opts.ss}" if opts.ss&.match(TIME_REGEX)
    oopts << " -to #{opts.to}" if opts.to&.match(TIME_REGEX)
  end

  def http
    Mechanize.new
  end

end
