require 'open3'

module Zipper

  SIZE_MB_LIMIT = 50

  Types = SymMash.new(
    video: {
      name: :video,
      ext:  :mp4,
      mime: 'video/mp4',
      opts: {width: 640, quality: 25, abrate: 64},
      # aac_he_v2 doesn't work with instagram
      cmd:  <<-EOC
nice ffmpeg -y -threads 12 -loglevel error -i %{infile} \
  -c:v libx264 -vf scale="%{width}:trunc(ow/a/2)*2%{vf}" -crf %{quality} \
    -maxrate:v %{maxrate} -bufsize %{bufsize} \
  -c:a libfdk_aac -profile:a aac_he -b:a %{abrate}k 
EOC
    },
    audio: {
      name: :audio,
      ext:  :m4a,
      mime: 'audio/aac',
      opts: {bitrate: 80},
      cmd:  <<-EOC
nice ffmpeg -vn -y -loglevel error -i %{infile} \
  -c:a libfdk_aac -profile:a aac_he -b:a %{bitrate}k 
EOC
    },
  )

  def zip_video infile, outfile, probe:, opts: SymMash.new
    opts.reverse_merge! Types.video.opts.deep_dup

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
    maxrate  = 8 * (0.98 * SIZE_MB_LIMIT * 1000).to_i / duration
    maxrate -= opts.abrate if maxrate > opts.abrate
    maxrate  = "#{maxrate}k"

    cmd = Types.video.cmd % {
      infile:  escape(infile),
      width:   opts.width,
      quality: opts.quality,
      abrate:  opts.abrate,
      maxrate: maxrate,
      bufsize: bufsize,
      vf:      vf,
    }
    apply_opts cmd
    cmd << " #{escape outfile}"

    run cmd
  end

  def zip_audio infile, outfile, probe:, opts: SymMash.new
    opts.reverse_merge! Types.audio.opts.deep_dup
    cmd = Types.audio.cmd % {
      infile:  escape(infile),
      outfile: escape(outfile),
      bitrate: opts.bitrate,
    }
    apply_opts cmd
    cmd << " #{escape outfile}"

    run cmd
  end
  
  def run cmd
    binding.pry if ENV['PRY_ZIPPER']
    Open3.capture3 cmd
  end

  def apply_opts cmd
    cmd.strip!
    cmd << " -ss #{opts.ss}" if opts.ss&.match(/\d?\d:\d\d/)
  end

  def escape f
    Shellwords.escape f
  end

end
