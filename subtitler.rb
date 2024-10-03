module Subtitler

  MODEL = ENV['WHISPER_MODEL']

  RUN_PATH    = "/run/media_downloader_bot"
  SOCKET_PATH = if File.writable? RUN_PATH then RUN_PATH else "#{__dir__}/tmp" end + '/whisper.cpp.socket'

  class Api < Roda
    plugin :indifferent_params
    route do |r|
      r.post do
        res = $model.transcribe_from_file params[:path], format: 'srt'
        res.to_h.to_json
      end
    end
  end

  def self.start
    DB.disconnect if defined? DB
    # whisper.cpp will lock ruby, run it with fork
    fork do
      Process.setproctitle 'whisper.cpp'
      $model = Whisper::Model.new MODEL
      server = Puma::Server.new Api.freeze.app
      server.add_unix_listener SOCKET_PATH
      puts SOCKET_PATH
      server.run.join
    ensure
      File.unlink SOCKET_PATH
    end unless File.exist? SOCKET_PATH # reuse another server
  end
  start

  def self.transcribe path
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

