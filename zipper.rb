require 'open3'

module Zipper

  SIZE_MB_LIMIT = 50

  CUDA         = false # slower while mining
  H264_OPTS    = if CUDA then '-hwaccel cuda -hwaccel_output_format cuda' else '' end
  H264_CODEC   = if CUDA then 'h264_nvenc' else 'libx264' end
  SCALE_KEY    = if CUDA then 'scale_npp' else 'scale' end
  H264_QUALITY = if CUDA then 33 else 25 end # to keep similar size

  # -spatial_aq:v 1 is too slow
  VIDEO_PRE_OPTS   = if CUDA then '-profile:v high -tune:v hq -level 4.1 -rc:v vbr -rc-lookahead:v 32 -aq-strength:v 15' else '' end
  VIDEO_PRE_OPTS  << " -vf #{SCALE_KEY}=\"%{width}:trunc(ow/a/2)*2%{vf}\""

  POST_OPTS        = " -map_metadata 0 -id3v2_version 3 -write_id3v1 1 %{metadata}"
  VIDEO_POST_OPTS  = "-movflags +faststart -movflags use_metadata_tags"
  VIDEO_POST_OPTS << " #{POST_OPTS}"

  Types = SymMash.new(
    video: {
      name:    :video,
      default: :h264,
      h264: {
        ext:  :mp4,
        mime: 'video/mp4',
        opts: {width: 640, quality: H264_QUALITY, abrate: 64},
        cmd:  <<-EOC
nice ffmpeg -y -threads 12 -loglevel error #{H264_OPTS} -i %{infile} #{VIDEO_PRE_OPTS} \
  -c:v #{H264_CODEC} -cq:v %{quality} -maxrate:v %{maxrate} -bufsize %{bufsize} #{VIDEO_POST_OPTS} \
  -c:a libfdk_aac -profile:a aac_he -b:a %{abrate}k 
        EOC
      },
      av1: {
        ext:  :mp4,
        mime: 'video/mp4',
        opts: {width: 720, quality: 40, abrate: 64},
        cmd:  <<-EOC
nice ffmpeg -y -threads 12 -loglevel error -i %{infile} #{VIDEO_PRE_OPTS} \
  -c:v libsvtav1 -crf %{quality} -svtav1-params mbr=%{maxrate} #{VIDEO_POST_OPTS} \
  -c:a libfdk_aac -profile:a aac_he -b:a %{abrate}k 
        EOC
      },
    },

    audio: {
      name:    :audio,
      default: :aac,
      aac: {
        ext:  :m4a,
        mime: 'audio/aac',
        opts: {bitrate: 80},
        # aac_he_v2 doesn't work with instagram
        cmd:  <<-EOC
nice ffmpeg -vn -y -loglevel error -i %{infile} \
  -c:a libfdk_aac -profile:a aac_he -b:a %{bitrate}k #{POST_OPTS}
        EOC
      },
      # Opus in Telegram Bots are considered voice messages
      opus: {
        ext:  :opus,
        mime: 'audio/aac',
        opts: {bitrate: 80},
        cmd:  <<-EOC
nice ffmpeg -vn -y -loglevel error -i %{infile} \
  -c:a libopus -b:a %{bitrate}k #{POST_OPTS}
        EOC
      },
    },
  )

  def zip_video infile, outfile, probe:, opts: SymMash.new
    opts.reverse_merge! opts.format.opts.deep_dup

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

    # max bitrate to fit SIZE_MB_LIMIT
    duration = probe.format.duration.to_i
    audsize  = (duration * opts.abrate/8) / 1000
    bufsize  = "#{SIZE_MB_LIMIT - audsize}M"
    maxrate  = 8 * (0.99 * SIZE_MB_LIMIT * 1000).to_i / duration
    maxrate -= opts.abrate if maxrate > opts.abrate
    maxrate  = "#{maxrate}k"

    cmd = opts.format.cmd % {
      infile:   escape(infile),
      width:    opts.width,
      quality:  opts.quality,
      abrate:   opts.abrate,
      maxrate:  maxrate,
      bufsize:  bufsize,
      metadata: metadata_args(opts.metadata),
      vf:       vf,
    }
    apply_opts cmd, opts
    cmd << " #{escape outfile}"

    run cmd
  end

  def zip_audio infile, outfile, probe:, opts: SymMash.new
    opts.reverse_merge! opts.format.opts.deep_dup

    cmd = opts.format.cmd % {
      infile:   escape(infile),
      bitrate:  opts.bitrate,
      metadata: metadata_args(opts.metadata),
    }

    apply_opts cmd, opts
    cmd << " #{escape outfile}"

    run cmd
  end

  protected 

  def metadata_args metadata
    (metadata || {}).map{ |k,v| "-metadata #{escape k}=#{escape v}" }.join ' '
  end
  
  def run cmd
    binding.pry if ENV['PRY_ZIPPER']
    puts cmd if ENV['PRINT_CMD']
    Open3.capture3 cmd
  end

  def apply_opts cmd, opts
    cmd.strip!
    cmd << " -ss #{opts.ss}" if opts.ss&.match(/\d?\d:\d\d/)
  end

  def escape f
    Shellwords.escape f
  end

end
