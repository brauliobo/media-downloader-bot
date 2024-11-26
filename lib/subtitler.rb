module Subtitler

  mattr_accessor :local

  MODEL = File.expand_path ENV['WHISPER_MODEL']
  raise "subtitler: can't find model" unless File.exist? MODEL

  mattr_accessor :api
  self.api = ENV['WHISPER_API']

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
    server.add_tcp_port URI.parse(api).port
    server.run.join

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

  def self.api_open?
    uri = URI.parse api
    Socket.tcp(uri.host, uri.port, connect_timeout: 5){ true } rescue false
  end

end

