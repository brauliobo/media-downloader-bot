require 'bundler/setup'
require 'active_support/all'
require 'dotenv'
require 'telegram/bot'

require 'tmpdir'
require 'shellwords'
require 'open3'
require 'mime/types'

require_relative 'exts/sym_mash'
require_relative 'bot/helpers'

class Bot

  attr_reader :bot

  include Helpers

  def initialize token
    @token = token
    @dir   = Dir.mktmpdir 'media-downloader-'
  end

  def start
    Telegram::Bot::Client.run @token, logger: Logger.new(STDOUT) do |bot|
      @bot = bot

      puts 'bot: started, listening'
      @bot.listen do |msg|
        Thread.new do
          next unless msg.is_a? Telegram::Bot::Types::Message
          react msg
        end
        Thread.new{ sleep 1 and abort } if @exit # wait for other msg processing and trigger systemd restart
      end
    end
  end

  def react msg
    download msg, msg.text
  end

  CMD = "youtube-dl -4 --user-agent 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36' -f worst --write-info-json '%{url}'"

  def download msg, url
    Dir.mktmpdir "media-downloader-#{url}" do |d|
      resp = send_message msg, "Downloading #{url}"
      Dir.chdir d do
        o, _e, _s = Open3.capture3 CMD % {url: url}
        edit_message msg, resp.result.message_id, text: o
        Dir.glob '*.info.json' do |f|
          info   = Hashie::Mash.new JSON.parse File.read f
          fnbase = File.basename info._filename, File.extname(info._filename)
          fn_in  = Dir.glob("#{fnbase}*").first
          fn_out = 'out.mp4'
          zip_video fn_in, fn_out

          ctype = MIME::Types.type_for(fn_out).first.content_type
          video = Faraday::UploadIO.new fn_out, ctype
          text  = "_#{info.title}_\n\n#{url}"
          send_message msg, text, type: 'video', video: video
          delete_message msg, resp.result.message_id, wait: nil
        end
      end
    end
  end

  def zip_video infile, outfile, width: 720, quality: 30
    cmd = <<-EOC
ffmpeg -loglevel quiet -i #{Shellwords.escape infile} \
  -c:v libx264 -vf scale="#{width}:trunc(ow/a/2)*2" -crf #{quality} \
  -c:a libfdk_aac -b:a 64k \
  #{Shellwords.escape outfile}
EOC
    system cmd
  end

  def zip_audio infile, outfile, bitrate: 80
    cmd = <<-EOC
ffmpeg -loglevel quiet -i #{Shellwords.escape infile} -f wav - |
opusenc --bitrate #{bitrate} --quiet - #{Shellwords.escape outfile}
EOC
    system cmd
  end

end
