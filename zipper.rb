class Zipper

  class_attribute :size_mb_limit
  self.size_mb_limit = 50

  PERCENT       = 0.97 # 3% less, up to 2% less proved to exceed limit (without Opus as audio 2% is enough)

  CUDA         = false # slower while mining
  H264_OPTS    = if CUDA then '-hwaccel cuda -hwaccel_output_format cuda' else '' end
  H264_CODEC   = if CUDA then 'h264_nvenc' else 'libx264' end
  SCALE_KEY    = if CUDA then 'scale_npp' else 'scale' end
  H264_QUALITY = if CUDA then 33 else 25 end # to keep similar size

  # -spatial_aq:v 1 is too slow
  VIDEO_PRE_OPTS   = if CUDA then '-profile:v high -tune:v hq -level 4.1 -rc:v vbr -rc-lookahead:v 32 -aq-strength:v 15' else '' end
  VIDEO_PRE_OPTS  << " -vf #{SCALE_KEY}=\"%{width}:trunc(ow/a/2)*2%{vf}\""
  VP9_PRE_OPTS     = " -vf #{SCALE_KEY}=\"%{width}:trunc(ow/a/8)*8%{vf}\""

  POST_OPTS        = " -map_metadata 0 -id3v2_version 3 -write_id3v1 1 %{metadata}"
  VIDEO_POST_OPTS  = "-movflags +faststart -movflags use_metadata_tags"
  VIDEO_POST_OPTS << " #{POST_OPTS}"

  Types = SymMash.new(
    video: {
      name:    :video,
      default: :h264,

      h264: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: 640, quality: H264_QUALITY, abrate: 64},
        vcopts: "-maxrate:v %{maxrate} -bufsize %{bufsize}",
        cmd: <<-EOC
nice ffmpeg -y -threads 12 -loglevel error #{H264_OPTS} -i %{infile} %{inputs} #{VIDEO_PRE_OPTS} \
  -c:v #{H264_CODEC} -cq:v %{quality} %{vcopts} #{VIDEO_POST_OPTS} \
  -c:a libopus -b:a %{abrate}k
        EOC
      },

      # FIXME: Can't control file size
      vp9: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: 720, quality: 50, vbrate: 200, abrate: 64},
        vcopts: "-b:v %{maxrate}k",
        cmd:  <<-EOC
nice ffmpeg -y -threads 12 -loglevel error -i %{infile} %{inputs} #{VP9_PRE_OPTS} \
  -c:v libsvt_vp9 -cq:v %{quality} %{vcopts} #{VIDEO_POST_OPTS} \
  -c:a libopus -b:a %{abrate}k
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
nice ffmpeg -y -threads 12 -loglevel error -i %{infile} %{inputs} #{VIDEO_PRE_OPTS} \
  -c:v libsvtav1 -crf %{quality} %{vcopts}  #{VIDEO_POST_OPTS} \
  -c:a libopus -b:a %{abrate}k
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
        cmd:  <<-EOC
nice ffmpeg -vn -y -loglevel error -i %{infile} %{inputs} \
  -c:a libopus -b:a %{bitrate}k #{POST_OPTS}
        EOC
      },

      aac: {
        ext:  :m4a,
        mime: 'audio/aac',
        opts: {bitrate: 96},
        # aac_he_v2 doesn't work with instagram
        cmd:  <<-EOC
nice ffmpeg -vn -y -loglevel error -i %{infile} %{inputs} \
  -c:a libfdk_aac -profile:a aac_he -b:a %{bitrate}k #{POST_OPTS}
        EOC
      },
    },
  )

  def self.zip_video infile, outfile, probe:, opts: SymMash.new
    inputs = ''
    opts.reverse_merge! opts.format.opts.deep_dup

    #inputs = "-i #{Sh.escape opts.cover} -map 1 -map 0" if opts.cover

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

    vf = ",#{opts.vf}" if opts.vf.present?

    if size_mb_limit
      # max bitrate to fit size_mb_limit
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
      inputs:   inputs,
      width:    opts.width,
      quality:  opts.quality,
      abrate:   opts.abrate,
      vbrate:   opts.vbrate,
      vcopts:   vcopts,
      metadata: metadata_args(opts.metadata),
      vf:       vf,
    }
    apply_opts cmd, opts

    # ignored by Telegram which only uses thumb parameter
    # also make the filesize a bit bigger
    #cmd << ' -c:0 png -disposition:0 attached_pic' if opts.cover

    cmd << " #{Sh.escape outfile}"

    Sh.run cmd
  end

  def self.zip_audio infile, outfile, probe:, opts: SymMash.new
    inputs = ''
    opts.reverse_merge! opts.format.opts.deep_dup

    cmd = opts.format.cmd % {
      infile:   Sh.escape(infile),
      inputs:   inputs,
      bitrate:  opts.bitrate,
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
