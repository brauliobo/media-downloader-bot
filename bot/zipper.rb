require 'open3'

module Zipper

  SIZE_MB_LIMIT = 50

  Types = SymMash.new(
    video: {
      name: :video,
      ext:  :mp4,
      opts: {width: 640, quality: 28, abrate: 64},
      # aac_he_v2 doesn't work with instagram
      cmd:  <<-EOC
nice ffmpeg -loglevel quiet -i %{infile} \
  -c:v libx264 -vf scale="%{width}:trunc(ow/a/2)*2" -crf %{quality} \
    -maxrate:v %{maxrate} -bufsize %{bufsize} \
  -c:a libfdk_aac -profile:a aac_he -b:a %{abrate}k \
  -y %{outfile}
EOC
    },
    audio: {
      name: :audio,
      ext:  :m4a,
      opts: {bitrate: 80},
      cmd:  <<-EOC
nice ffmpeg -loglevel quiet -i %{infile} \
  -c:a libfdk_aac -profile:a aac_he -b:a %{bitrate}k \
  -vn -y %{outfile}
EOC
# Opus in Telegram Bots are considered voice messages
#      ext:  :opus,
#      cmd:  <<-EOC
#ffmpeg -loglevel quiet -i %{infile} -f wav - |
#opusenc --bitrate %{bitrate} --quiet - %{outfile}
#EOC
    },
  )

  def zip_video infile, outfile, opts = Types.video.opts.deep_dup, probe:
    # portrait image
    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
    opts.width /= 2 if vstrea.width < vstrea.height
    # max bitrate to fit SIZE_MB_LIMIT
    duration = probe.format.duration.to_i
    audsize  = (duration * opts.abrate/8) / 1000
    bufsize  = "#{SIZE_MB_LIMIT - audsize}M"
    maxrate  = 8 * (0.98 * SIZE_MB_LIMIT * 1000).to_i / duration
    maxrate -= opts.abrate if maxrate > opts.abrate
    maxrate  = "#{maxrate}k"

    cmd = Types.video.cmd % {
      infile:  Shellwords.escape(infile),
      outfile: Shellwords.escape(outfile),
      width:   opts.width,
      quality: opts.quality,
      abrate:  opts.abrate,
      maxrate: maxrate,
      bufsize: bufsize,
    }

    binding.pry if ENV['PRY_ZIPPER']
    Open3.capture3 cmd
  end

  def zip_audio infile, outfile, opts = Types.audio.opts.deep_dup, probe:
    cmd = Types.audio.cmd % {
      infile:  Shellwords.escape(infile),
      outfile: Shellwords.escape(outfile),
      bitrate: opts.bitrate,
    }
    Open3.capture3 cmd
  end

end
