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
  SUB_STYLE = 'Fontname=Roboto,OutlineColour=&H40000000,BorderStyle=3'.freeze

  THREADS = ENV['THREADS']&.to_i || 16
  FFMPEG  = "nice ffmpeg -y -threads #{THREADS} -loglevel error"

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
  VID_WIDTH_REDUC = SymMash.new width: 80, minutes: 5

  def self.zip_video infile, outfile, probe:, opts: SymMash.new
    vf = ''; iopts = ''; oopts = ''; dopts = opts.format.opts
    opts.reverse_merge! dopts

    sub = probe.streams.find{ |s| s.codec_type == 'subtitle' }
    vf << ",subtitles=#{Sh.escape infile}:si=0:force_style='#{SUB_STYLE}'" if sub

    if speed = opts.speed&.to_f
      vf    << ",setpts=PTS*1/#{speed}"
      oopts << " -af atempo=#{speed}"
    else speed = 1
    end

    vf << ",mpdecimate" unless opts.nompdecimate
    vf << ",#{opts.vf}" if opts.vf.present?

    # FIXME: conflict with MP4 vsync vfr
    iopts << " -r #{opts.maxfr.to_i}" if opts.maxfr

    iopts << " -ar #{opts.ar.to_i}" if opts.ar

    # Workaround for "Channel layout change is not supported"
    # https://www.atlas-informatik.ch/multimediaXpert/Convert.en.html
    iopts << " -ac #{opts.ac.to_i}" if opts.ac

    # convert input
    opts.width   = opts.width.to_i
    opts.quality = opts.quality.to_i
    opts.abrate  = opts.abrate.to_i

    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
    if opts.vf&.index 'transpose'
    else # portrait image
      opts.width /= 2 if vstrea.width < vstrea.height
    end
    # lower resolution
    opts.width = vstrea.width if vstrea.width < opts.width

    if size_mb_limit # max bitrate to fit size_mb_limit
      duration = probe.format.duration.to_f / speed
      minutes  = (duration / 60).ceil

      # reduce resolution
      if minutes > VID_DURATION_THLD and opts.width > dopts.width/3
        reduc,intv  = VID_WIDTH_REDUC.values_at :width, :minutes
        opts.width  = opts.width - reduc * ((minutes - VID_DURATION_THLD).to_f / intv).ceil
        opts.width  = dopts.width/3 if opts.width < dopts.width/3
        opts.width -= 1 if opts.width % 2 == 1
      end

      audsize  = (duration * opts.abrate.to_f/8) / 1000
      vidsize  = (size_mb_limit - audsize).to_i
      bufsize  = "#{vidsize}M"

      maxrate  = (8*(opts.percent * vidsize * 1000) / duration).to_i
      maxrate  = opts.vbrate if opts.vbrate and maxrate > opts.vbrate
      maxrate  = "#{maxrate}k"
      szopts   = opts.format.szopts % {maxrate:, bufsize:}
    end

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
      metadata: metadata_args(opts.metadata),
    }
    apply_opts cmd, opts

    cmd << " #{Sh.escape outfile}"
    Sh.run cmd
  end

  def self.zip_audio infile, outfile, probe:, opts: SymMash.new
    iopts = ''; oopts = ''
    opts.reverse_merge! opts.format.opts.deep_dup

    if speed = opts.speed&.to_f
      iopts << " -af atempo=#{speed}"
    else speed = 1
    end

    iopts << " -ar #{opts.freq.to_i}" if opts.freq
    iopts << " -ac #{opts.ac.to_i}" if opts.ac

    if size_mb_limit # max bitrate to fit size_mb_limit
      duration = probe.format.duration.to_f / speed
      opts.bitrate = (opts.percent * 8*size_mb_limit*1000).to_f / duration if max_audio_duration(opts.bitrate) < duration / 60
    end

    cmd = opts.format.cmd % {
      infile:   Sh.escape(infile),
      iopts:    iopts,
      oopts:    oopts,
      abrate:   opts.bitrate,
      metadata: metadata_args(opts.metadata),
    }
    apply_opts cmd, opts

    cmd << " #{Sh.escape outfile}"
    Sh.run cmd
  end

  protected 

  def self.metadata_args metadata
    (metadata || {}).map{ |k,v| "-metadata #{Sh.escape k}=#{Sh.escape v}" }.join ' '
  end
  
  def self.apply_opts cmd, opts
    cmd.strip!
    cmd << " -ss #{opts.ss}" if opts.ss&.match(TIME_REGEX)
    cmd << " -to #{opts.to}" if opts.to&.match(TIME_REGEX)
  end

end
