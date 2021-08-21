module Zipper

  Types = SymMash.new(
    video: {
      name: :video,
      ext:  :mp4,
      cmd:  <<-EOC
ffmpeg -loglevel quiet -i %{infile} \
  -c:v libx264 -vf scale="%{width}:trunc(ow/a/2)*2" -crf %{quality} \
  -c:a libfdk_aac -profile:a aac_he_v2 -b:a 64k \
  %{outfile}
EOC
    },
    audio: {
      name: :audio,
      ext:  :m4a,
      cmd:  <<-EOC
ffmpeg -loglevel quiet -i %{infile} \
  -c:a libfdk_aac -profile:a aac_he_v2 -b:a %{bitrate}k
  %{outfile}
EOC
# Opus in Telegram Bots are considered voice messages
#      ext:  :opus,
#      cmd:  <<-EOC
#ffmpeg -loglevel quiet -i %{infile} -f wav - |
#opusenc --bitrate %{bitrate} --quiet - %{outfile}
#EOC
    },
  )

  def zip_video infile, outfile, width: 720, quality: 30
    system Types.video.cmd % {
      infile:  Shellwords.escape(infile),
      outfile: Shellwords.escape(outfile),
      width:   width,
      quality: quality,
    }
  end

  def zip_audio infile, outfile, bitrate: 80
    system Types.audio.cmd % {
      infile:  Shellwords.escape(infile),
      outfile: Shellwords.escape(outfile),
      bitrate: bitrate,
    }
  end

end
