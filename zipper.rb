class Zipper

  class_attribute :size_mb_limit
  self.size_mb_limit = 50

  VID_PERCENT  = 0.99
  OPUS_PERCENT = 0.95

  CUDA         = false # slower while mining
  H264_OPTS    = if CUDA then '-hwaccel cuda -hwaccel_output_format cuda' else '' end
  H264_CODEC   = if CUDA then 'h264_nvenc' else 'libx264' end
  H264_QUALITY = if CUDA then 33 else 25 end # to keep similar size
  SCALE_KEY    = if CUDA then 'scale_npp' else 'scale' end

  SCALE_M2 = "#{SCALE_KEY}='%{width}:trunc(ow/a/2)*2'"
  SCALE_M8 = "#{SCALE_KEY}='%{width}:trunc(ow/a/8)*8'"

  META             = "-metadata downloaded_with=t.me/media_downloader_2bot"
  POST_OPTS        = " -map_metadata 0 -id3v2_version 3 -write_id3v1 1 #{META} %{metadata}"
  VIDEO_POST_OPTS  = "-movflags +faststart -movflags use_metadata_tags"
  VIDEO_POST_OPTS << " #{POST_OPTS}"
  VIDEO_POST_OPTS << '-profile:v high -tune:v hq -level 4.1 -rc:v vbr -rc-lookahead:v 32 -aq-strength:v 15' if CUDA 

  ENC_OPUS = '-c:a libopus -b:a %{abrate}k'
  if `ffmpeg -encoders 2>&1 > /dev/null | grep fdk_aac`.present?
    # aac_he_v2 doesn't work with instagram
    ENC_AAC = '-c:a libfdk_aac -profile:a aac_he -b:a %{abrate}k'
  else
    ENC_AAC = '-c:a aac -b:a %{abrate}k'
  end
  ENC_MP3 = '-c:a libmp3lame -abr 1 -b:a %{abrate}k'

  SUB_STYLE = 'Fontname=Roboto,OutlineColour=&H40000000,BorderStyle=3'

  THREADS = ENV['THREADS']&.to_i || 16
  FFMPEG  = "nice ffmpeg -y -threads #{THREADS} -loglevel error"

  Types = SymMash.new(
    video: {
      name:    :video,
      default: :h264,

      h264: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: 720, quality: H264_QUALITY, abrate: 64, apercent: OPUS_PERCENT},
        szopts: "-maxrate:v %{maxrate} -bufsize %{bufsize}",
        cmd: <<-EOC
#{FFMPEG} #{H264_OPTS} -i %{infile} -vf "#{SCALE_M2}%{vf}" %{iopts} \
  -c:v #{H264_CODEC} -cq:v %{quality} %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      # FIXME: Can't control file size
      vp9: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: 720, quality: 50, vbrate: 200, abrate: 64, apercent: OPUS_PERCENT},
        szopts: "-b:v %{maxrate}",
        cmd:  <<-EOC
#{FFMPEG} -i %{infile} -vf "#{SCALE_M8}%{vf}" %{iopts} \
  -c:v libsvt_vp9 -cq:v %{quality} %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      # Doesn't work on iOS :(
      # MBR reduces quality too much, https://gitlab.com/AOMediaCodec/SVT-AV1/-/issues/2065
      av1: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: 720, quality: 40, vbrate: 200, abrate: 64, apercent: OPUS_PERCENT},
        szopts: "-b:v %{vbrate}k -svtav1-params mbr=%{maxrate}",
        cmd:  <<-EOC
#{FFMPEG} -i %{infile} -vf "#{SCALE_M2}%{vf}" %{iopts} \
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
        opts: {bitrate: 96, percent: OPUS_PERCENT},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{ENC_OPUS} #{POST_OPTS} %{oopts}"
      },

      aac: {
        ext:  :m4a,
        mime: 'audio/aac',
        opts: {bitrate: 96, percent: 0.98},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{ENC_AAC} #{POST_OPTS} %{oopts}" 
      },

      mp3: {
        ext:  :mp3,
        mime: 'audio/mp3',
        opts: {bitrate: 128, percent: 1},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{ENC_MP3} #{POST_OPTS} %{oopts}" 
      },
    },
  )

  def self.max_audio_duration br
    1000 * Zipper.size_mb_limit / (br / 8) / 60
  end

  VID_DURATION_THLD = if size_mb_limit then 25 else Float::INFINITY end
  AUD_DURATION_THLD = if size_mb_limit then max_audio_duration Types.audio.opus.opts.bitrate else Float::INFINITY end

  VID_WIDTH_REDUC = SymMash.new width: 120, minutes: 5

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

    vf << ",#{opts.vf}" if opts.vf.present?

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
        reduc,intv = VID_WIDTH_REDUC.values_at :width, :minutes
        opts.width = opts.width - reduc * ((minutes - VID_DURATION_THLD).to_f / intv).ceil
        opts.width = dopts.width/3 if opts.width < dopts.width/3 
      end

      audsize  = (duration * opts.abrate.to_f/8) / 1000
      vidsize  = (size_mb_limit - audsize).to_i
      bufsize  = "#{vidsize}M"

      maxrate  = 8*(VID_PERCENT * vidsize * 1000).to_i / duration
      maxrate  = "#{maxrate}k"
      opts.abrate = (opts.apercent * opts.abrate).round
      szopts   = opts.format.szopts % {maxrate:, bufsize:}
    end

    cmd = opts.format.cmd % {
      infile:   Sh.escape(infile),
      vf:       vf,
      iopts:    iopts,
      oopts:    oopts,
      width:    opts.width,
      quality:  opts.quality,
      acodec:   acodec_opts(opts.acodec, opts.abrate),
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

  def self.acodec_opts acodec, abrate
    case acodec&.to_sym
    when :aac then ENC_AAC
    when :mp3 then ENC_MP3
    else ENC_OPUS
    end % {abrate:}
  end

  def self.metadata_args metadata
    (metadata || {}).map{ |k,v| "-metadata #{Sh.escape k}=#{Sh.escape v}" }.join ' '
  end
  
  def self.apply_opts cmd, opts
    cmd.strip!
    cmd << " -ss #{opts.ss}" if opts.ss&.match(/\d?\d:\d\d/)
    cmd << " -to #{opts.to}" if opts.to&.match(/\d?\d:\d\d/)
  end

end
