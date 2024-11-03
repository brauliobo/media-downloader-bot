module Subtitler

  mattr_accessor :local

  MODEL = ENV['WHISPER_MODEL']

  RUN_PATH    = "/run/media_downloader_bot"
  SOCKET_PATH = if File.writable? RUN_PATH then RUN_PATH else "#{__dir__}/../tmp" end + '/whisper.cpp.socket'

  def self.init
    $model ||= Whisper::Model.new MODEL
    $mutex ||= Mutex.new
  end
  def self.local_transcribe path
    Subtitler.init
    $mutex.synchronize do
      $model.transcribe_from_file path, format: 'srt'
    end
  end

  class Api < Roda
    plugin :indifferent_params
    route do |r|
      r.post do
        res = Subtitler.local_transcribe params[:path]
        res.to_h.to_json
      end
    end
  end

  def self.start_api
    Subtitler.init
    server = Puma::Server.new Api.freeze.app
    server.add_unix_listener SOCKET_PATH
    server.run.join

    at_exit{ File.unlink SOCKET_PATH }
    sleep 1 until File.exist? SOCKET_PATH
  end

  def self.transcribe path
    return local_transcribe path if local
    client_post path: path
  end

  def self.client_post obj
    @http ||= NetX::HTTPUnix.new("unix://#{SOCKET_PATH}").tap do |http|
      http.read_timeout = 1.hour.to_i
    end
    req = Net::HTTP::Post.new '/'
    req.set_form_data obj
    res = @http.request req
    SymMash.new JSON.parse res.body
  end

end

