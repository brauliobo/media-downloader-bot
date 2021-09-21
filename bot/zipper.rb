module Zipper

  SIZE_MB_LIMIT = 50

  Types = SymMash.new(
    video: {
      name: :video,
      ext:  :mp4,
      opts: {width: 640, quality: 25},
      # aac_he_v2 doesn't work with instagram
      cmd:  <<-EOC
nice ffmpeg -loglevel quiet -i %{infile} \
  -c:v libx264 -vf scale="%{width}:trunc(ow/a/2)*2" -crf %{quality} \
    -maxrate:v %{maxrate} -bufsize 5M \
  -c:a libfdk_aac -profile:a aac_he -b:a 64k \
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

  def zip_video infile, outfile, opts = Types.video.opts, probe:
    # portrait image
    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
    opts.width /= 2 if vstrea.width < vstrea.height
    # max bitrate to fit SIZE_MB_LIMIT
    maxrate = "#{(0.98 * SIZE_MB_LIMIT * 1000 / probe.format.duration.to_i - 64).to_i}k"

    system Types.video.cmd % {
      infile:  Shellwords.escape(infile),
      outfile: Shellwords.escape(outfile),
      width:   opts.width,
      quality: opts.quality,
      maxrate: maxrate,
    }
  end

  def zip_audio infile, outfile, opts = Types.audio.opts, probe:
    system Types.audio.cmd % {
      infile:  Shellwords.escape(infile),
      outfile: Shellwords.escape(outfile),
      bitrate: opts.bitrate,
    }
  end

end
