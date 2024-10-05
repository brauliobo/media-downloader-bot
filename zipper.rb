class Zipper

  class_attribute :size_mb_limit
  self.size_mb_limit = 50

  VID_WIDTH    = 640
  VID_PERCENT  = 0.99

  TIME_REGEX   = /(?:\d?\d:)(?:\d?\d:)\d\d/

  CUDA         = false # slower while mining
  H264_OPTS    = if CUDA then '-hwaccel cuda -hwaccel_output_format cuda' else '' end
  H264_CODEC   = if CUDA then 'h264_nvenc' else 'libx264' end
  H264_QUALITY = if CUDA then 33 else 25 end # to keep similar size
  SCALE_KEY    = if CUDA then 'scale_npp' else 'scale' end

  VFR_OPTS    = '-vsync vfr'
  VF_SCALE_M2 = "#{SCALE_KEY}='%{width}:trunc(ow/a/2)*2'".freeze
  VF_SCALE_M8 = "#{SCALE_KEY}='%{width}:trunc(ow/a/8)*8'".freeze

  META             = "-metadata downloaded_with=t.me/media_downloader_2bot".freeze
  POST_OPTS        = " -map_metadata 0 -id3v2_version 3 -write_id3v1 1 #{META} %{metadata}".freeze
  VIDEO_POST_OPTS  = "-movflags +faststart -movflags use_metadata_tags"
  VIDEO_POST_OPTS << " #{POST_OPTS}"
  VIDEO_POST_OPTS << '-profile:v high -tune:v hq -level 4.1 -rc:v vbr -rc-lookahead:v 32 -aq-strength:v 15' if CUDA 
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
  SUB_STYLE = {
    Fontsize:      20,
    Fontname:      'Roboto',
    OutlineColour: '&H40000000',
    BorderStyle:   3,
  }.map{ |k,v| "#{k}=#{v}" }.join(',')

  THREADS = ENV['THREADS']&.to_i || 16
  FFMPEG  = "ffmpeg -y -threads #{THREADS} -loglevel error"

  Types = SymMash.new(
    video: {
      name:    :video,
      default: :h264,

      h264: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, quality: H264_QUALITY, abrate: 64, acodec: :aac, percent: VID_PERCENT}, #whatsapp can't handle opus in h264
        szopts: "-maxrate:v %{maxrate} -bufsize %{bufsize}",
        cmd: <<-EOC
#{FFMPEG} #{H264_OPTS} -i %{infile} -vf "#{VF_SCALE_M2}%{vf}" #{VFR_OPTS} %{iopts} \
  -c:v #{H264_CODEC} -crf %{quality} %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      h265: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, quality: H264_QUALITY, abrate: 64, acodec: :aac, percent: VID_PERCENT}, #whatsapp can't handle opus in h264
        szopts: "-maxrate:v %{maxrate} -bufsize %{bufsize}",
        cmd: <<-EOC
#{FFMPEG} -i %{infile} -vf "#{VF_SCALE_M2}%{vf}" #{VFR_OPTS} %{iopts} \
  -c:v libx265 -crf %{quality} -preset fast %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      # VP9 doesn't seem to respect low bitrates:
      # - it can't control file size in quality mode,
      # - target bitrate mode also not ensuring desired bitrate
      vp9: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, vbrate: 835, abrate: 64, acodec: :aac, percent: 0.97},
        szopts: "-rc vbr -b:v %{maxrate}",
        cmd:  <<-EOC
#{FFMPEG} -i %{infile} -vf "#{VF_SCALE_M8}%{vf}" #{VFR_OPTS} %{iopts} \
  -c:v libsvt_vp9 %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      # Doesn't work on iOS :(
      # MBR reduces quality too much, https://gitlab.com/AOMediaCodec/SVT-AV1/-/issues/2065
      av1: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, quality: 40, vbrate: 200, abrate: 64, acodec: :opus, percent: VID_PERCENT},
        szopts: "-b:v %{vbrate}k -svtav1-params mbr=%{maxrate}",
        cmd:  <<-EOC
#{FFMPEG} -i %{infile} -vf "#{VF_SCALE_M2}%{vf}" #{VFR_OPTS} %{iopts} \
  -c:v libsvtav1 -crf %{quality} %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },
    },

    audio: {
      name:    :audio,
      default: :opus,

      opus: {
        ext:  :opus,
        mime: 'audio/aac',
        opts: {bitrate: 96, percent: AUDIO_ENC.opus.percent},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{AUDIO_ENC.opus.encode} #{POST_OPTS} %{oopts}"
      },

      aac: {
        ext:  :m4a,
        mime: 'audio/aac',
        opts: {bitrate: 96, percent: AUDIO_ENC.aac.percent},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{AUDIO_ENC.aac.encode} #{POST_OPTS} %{oopts}"
      },

      mp3: {
        ext:  :mp3,
        mime: 'audio/mp3',
        opts: {bitrate: 128, percent: AUDIO_ENC.mp3.percent},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{AUDIO_ENC.mp3.encode} #{POST_OPTS} %{oopts}"
      },
    },
  )

  def self.max_audio_duration br
    1000 * Zipper.size_mb_limit / (br.to_i / 8) / 60
  end

  VID_DURATION_THLD = if size_mb_limit then 25 else Float::INFINITY end
  AUD_DURATION_THLD = if size_mb_limit then max_audio_duration Types.audio.opus.opts.bitrate else Float::INFINITY end

  # reduce width for every minutes interval exceeding VID_DURATION_THLD
  VID_WIDTH_REDUC = SymMash.new width: 80, minutes: 8
  AUD_BRATE_REDUC = SymMash.new brate:  8, minutes: 8

  def self.zip_video *args, **params
    self.new(*args, **params).zip_video
  end
  def self.zip_audio *args, **params
    self.new(*args, **params).zip_audio
  end
  def self.extract_srt infile, language
    self.new(infile, nil, opts: SymMash.new(format: {})).extract_srt language
  end

  attr_reader :infile, :outfile, :probe
  attr_reader :iopts, :oopts, :dopts, :opts
  attr_reader :vf
  attr_reader :type

  def initialize infile, outfile, probe: nil, opts: SymMash.new
    @infile  = infile
    @outfile = outfile
    @probe   = probe || Prober.for(infile)

    @iopts = ''; @oopts = ''; @dopts = opts.format.opts
    @opts = opts
    @opts.reverse_merge! dopts

    @vf = ''
    @vf << ",#{opts.vf}" if opts.vf.present?

    opts.speed   = opts.speed&.to_f
    opts.width   = opts.width&.to_i
    opts.quality = opts.quality&.to_i
    opts.abrate  = opts.abrate&.to_i
  end

  def video?; @type == :video; end
  def audio?; @type == :audio; end

  def zip_video
    @type = :video

    check_width
    reduce_framerate
    limit_framerate
    apply_audio_rate
    apply_audio_channels

    apply_subtitle
    apply_speed
    szopts = apply_video_size_limits

    aenc   = AUDIO_ENC[opts.acodec&.to_sym] || AUDIO_ENC.opus
    opts.abrate = (aenc.percent * opts.abrate).round if size_mb_limit
    acodec = aenc.encode % {abrate: opts.abrate}

    cmd = opts.format.cmd % {
      infile:   Sh.escape(infile),
      vf:       vf,
      iopts:    iopts,
      oopts:    oopts,
      width:    opts.width,
      quality:  opts.quality,
      acodec:   acodec,
      vbrate:   opts.vbrate,
      szopts:   szopts,
      metadata: metadata_args,
    }
    apply_opts cmd, opts

    cmd << " #{Sh.escape outfile}"
    Sh.run cmd
  end

  def zip_audio
    @type = :audio

    apply_audio_rate
    apply_audio_channels

    apply_speed
    apply_audio_size_limit

    cmd = opts.format.cmd % {
      infile:   Sh.escape(infile),
      iopts:    iopts,
      oopts:    oopts,
      abrate:   opts.bitrate,
      metadata: metadata_args,
    }
    apply_opts cmd, opts

    cmd << " #{Sh.escape outfile}"
    Sh.run cmd
  end

  def extract_srt lang_or_index
    srtfile = "#{File.basename infile, File.extname(infile)}.srt"

    index = lang_or_index
    index = probe.streams.select{ |s| s.codec_type == 'subtitle' }.index{ |s| s.tags.language == index } || 0

    srt, _, _ = Sh.run <<-EOC
ffmpeg -loglevel error -i #{Sh.escape infile} -map 0:s:#{index} -c:s srt -f srt -
    EOC
    srt
  end

  protected

  def reduce_framerate
    return unless opts.nompdecimate
    vf << ",mpdecimate"
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

    duration = probe.format.duration.to_f / opts.speed
    opts.bitrate = (opts.percent * 8*size_mb_limit*1000).to_f / duration if self.class.max_audio_duration(opts.bitrate) < duration / 60
  end

  def apply_video_size_limits
    return unless size_mb_limit

    duration = probe.format.duration.to_f / opts.speed
    minutes  = (duration / 60).ceil

    # reduce resolution
    if minutes > VID_DURATION_THLD and opts.width > dopts.width/3
      reduc,intv  = VID_WIDTH_REDUC.values_at :width, :minutes
      opts.width -= reduc * ((minutes - VID_DURATION_THLD).to_f / intv).ceil
      opts.width  = dopts.width/3 if opts.width < dopts.width/3
      opts.width -= 1 if opts.width % 2 == 1
    end
    # reduce audio bitrate
    if minutes > VID_DURATION_THLD and opts.abrate > dopts.abrate/2
      reduc,intv   = AUD_BRATE_REDUC.values_at :brate, :minutes
      opts.abrate -= reduc * ((minutes - VID_DURATION_THLD).to_f / intv).ceil
      opts.abrate  = dopts.abrate/2 if opts.abrate < dopts.abrate/2
    end

    audsize  = (duration * opts.abrate.to_f/8) / 1000
    vidsize  = (size_mb_limit - audsize).to_i
    bufsize  = "#{vidsize}M"

    maxrate  = (8*(opts.percent * vidsize * 1000) / duration).to_i
    maxrate  = opts.vbrate if opts.vbrate and maxrate > opts.vbrate
    maxrate  = "#{maxrate}k"

    opts.format.szopts % {maxrate:, bufsize:}
  end

  def apply_speed
    if opts.speed
      vf    << ",setpts=PTS*1/#{opts.speed}" if video?
      oopts << " -af atempo=#{opts.speed}"
    else opts.speed = 1
    end
  end

  def check_width
    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
    if opts.vf&.index 'transpose'
    else # portrait image
      opts.width /= 2 if vstrea.width < vstrea.height
    end

    # lower resolution
    opts.width = vstrea.width if vstrea.width < opts.width
  end

  def apply_subtitle
    subs = probe.streams.select{ |s| s.codec_type == 'subtitle' }
    return if subs.blank? and !opts.lang and !opts.subs

    subs.each{ |s| s.lang = ISO_639.find_by_code(s.tags.language).alpha2 }

    if subs.present? and index = (subs.index{ |s| opts.lang == s.lang } || 0)
      srt = extract_srt index
      lng = subs[index].lang
    else
      res = Subtitler.transcribe infile
      srt,lng = res.output,res.language
    end

    srt = Translator.translate_srt srt, from: lng, to: opts.lang if opts.lang and opts.lang != lng

    tmpf = Tempfile.new 'subtitle'
    tmpf.write srt
    tmpf.flush

    vf << ",subtitles=#{Sh.escape tmpf.path}:force_style='#{SUB_STYLE}'"
  end

  def metadata_args
    (opts.metadata || {}).map{ |k,v| "-metadata #{Sh.escape k}=#{Sh.escape v}" }.join ' '
  end
  
  def apply_opts cmd, opts
    cmd.strip!
    cmd << " -ss #{opts.ss}" if opts.ss&.match(TIME_REGEX)
    cmd << " -to #{opts.to}" if opts.to&.match(TIME_REGEX)
  end

end
