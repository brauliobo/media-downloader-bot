require 'net/http/post/multipart'

class Subtitler
  module WhisperCpp

    mattr_accessor :local

    def transcribe path
      return local_transcribe path if local
      client_post path: path
    end

    def local_transcribe path
      WhisperCpp.init
      $mutex.synchronize do
        sleep 1 # try concurrency fix
        $model.transcribe_from_file path, format: 'srt'
      end
    end

    protected

    MODEL = File.expand_path ENV['WHISPER_MODEL']
    raise "subtitler: can't find model" unless File.exist? MODEL if ENV['WHISPER']

    mattr_accessor :api
    self.api = URI.parse ENV['WHISPER_API']

    def self.init
      $model ||= Whisper::Model.new MODEL
      $mutex ||= Mutex.new
    end

    def self.start_api
      init
      require 'puma'
      server = Puma::Server.new Api.freeze.app
      server.add_tcp_listener api.host, api.port
      server.run.tap do
        puts "Listening on #{api}"
      end.join
    end

    class Api < Roda
      plugin :indifferent_params
      include WhisperCpp
      route do |r|
        r.post do
          res = local_transcribe params[:path][:tempfile].path
          res.to_h.to_json
        end
      end
    end

    def client_post obj
      @http ||= Net::HTTP.new(api.host, api.port).tap do |http|
        http.read_timeout = 1.hour.to_i
      end

      file = UploadIO.new obj[:path], 'application/octet-stream'
      req = Net::HTTP::Post::Multipart.new api.path, path: file
      res = @http.request req
      
      SymMash.new JSON.parse res.body
    end

    def api_open?
      Socket.tcp(api.host, api.port, connect_timeout: 5){ true } rescue false
    end

  end

end
