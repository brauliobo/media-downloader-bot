class Zipper

  class_attribute :size_mb_limit
  self.size_mb_limit = 50

  PERCENT       = 0.95 # 3% less, up to 2% less proved to exceed limit (without Opus as audio 2% is enough)

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

  ENC_OPUS = "-c:a libopus -b:a %{abrate}k"
  if `ffmpeg -codecs | grep fdk_aac`.present?
    # aac_he_v2 doesn't work with instagram
    ENC_AAC = "-c:a libfdk_aac -profile:a aac_he -b:a %{abrate}k"
  else
    ENC_AAC = "-c:a aac -b:a %{abrate}k"
  end

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
        opts:   {width: 720, quality: H264_QUALITY, abrate: 64},
        vcopts: "-maxrate:v %{maxrate} -bufsize %{bufsize}",
        cmd: <<-EOC
#{FFMPEG} #{H264_OPTS} -i %{infile} -vf "#{SCALE_M2}%{vf}" %{iopts} \
  -c:v #{H264_CODEC} -cq:v %{quality} %{vcopts} #{ENC_OPUS} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      # FIXME: Can't control file size
      vp9: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: 720, quality: 50, vbrate: 200, abrate: 64},
        vcopts: "-b:v %{maxrate}k",
        cmd:  <<-EOC
#{FFMPEG} -i %{infile} -vf "#{SCALE_M8}%{vf}" %{iopts} \
  -c:v libsvt_vp9 -cq:v %{quality} %{vcopts} #{ENC_OPUS} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      # Doesn't work on iOS :(
      # MBR reduces quality too much, https://gitlab.com/AOMediaCodec/SVT-AV1/-/issues/2065
      av1: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: 720, quality: 40, vbrate: 200, abrate: 64},
        vcopts: "-b:v %{vbrate}k -svtav1-params mbr=%{maxrate}",
        cmd:  <<-EOC
#{FFMPEG} -i %{infile} -vf "#{SCALE_M2}%{vf}" %{iopts} \
  -c:v libsvtav1 -crf %{quality} %{vcopts} #{ENC_OPUS} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },
    },

    audio: {
      name:    :audio,
      default: :opus,

      opus: {
        ext:  :opus,
        mime: 'audio/aac',
        opts: {bitrate: 96},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{ENC_OPUS} #{POST_OPTS} %{oopts}"
      },

      aac: {
        ext:  :m4a,
        mime: 'audio/aac',
        opts: {bitrate: 96},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{ENC_AAC} #{POST_OPTS} %{oopts}" 
      },
    },
  )

  def self.zip_video infile, outfile, probe:, opts: SymMash.new
    vf = ''; iopts = ''; oopts = ''
    opts.reverse_merge! opts.format.opts.deep_dup

    sub = probe.streams.find{ |s| s.codec_type == 'subtitle' }
    vf << ",subtitles=#{Sh.escape infile}:si=0:force_style='#{SUB_STYLE}'" if sub

    if speed = opts.speed&.to_f
      vf    << ",setpts=PTS*1/#{Sh.escape speed}"
      oopts << " -af atempo=#{Sh.escape speed}"
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
      duration = probe.format.duration.to_i
      audsize  = (duration * opts.abrate/8) / 1000
      bufsize  = "#{size_mb_limit - audsize}M"
      maxrate  = 8 * (PERCENT * size_mb_limit * 1000).to_i / duration
      maxrate -= opts.abrate if maxrate > opts.abrate
      maxrate  = "#{maxrate}k"
      vcopts   = opts.format.vcopts % {maxrate:, bufsize:}
    end

    cmd = opts.format.cmd % {
      infile:   Sh.escape(infile),
      vf:       vf,
      iopts:    iopts,
      oopts:    oopts,
      width:    opts.width,
      quality:  opts.quality,
      abrate:   opts.abrate,
      vbrate:   opts.vbrate,
      vcopts:   vcopts,
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
      iopts << " -af atempo=#{Sh.escape speed}"
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
    cmd << " -ss #{opts.ss}" if opts.ss&.match(/\d?\d:\d\d/)
  end

end
