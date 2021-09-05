module Zipper

  Types = SymMash.new(
    video: {
      name: :video,
      ext:  :mp4,
      opts: {width: 640, quality: 28},
      cmd:  <<-EOC
ffmpeg -loglevel quiet -i %{infile} \
  -c:v libx264 -vf scale="%{width}:trunc(ow/a/2)*2" -crf %{quality} \
  -c:a libfdk_aac -profile:a aac_he_v2 -b:a 64k \
  -y %{outfile}
EOC
    },
    audio: {
      name: :audio,
      ext:  :m4a,
      opts: {bitrate: 80},
      cmd:  <<-EOC
ffmpeg -loglevel quiet -i %{infile} \
  -c:a libfdk_aac -profile:a aac_he_v2 -b:a %{bitrate}k \
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

  def zip_video infile, outfile, opts = Types.video.opts
    system Types.video.cmd % {
      infile:  Shellwords.escape(infile),
      outfile: Shellwords.escape(outfile),
      width:   opts.width,
      quality: opts.quality,
    }
  end

  def zip_audio infile, outfile, opts = Types.audio.opts
    system Types.audio.cmd % {
      infile:  Shellwords.escape(infile),
      outfile: Shellwords.escape(outfile),
      bitrate: opts.bitrate,
    }
  end

end
