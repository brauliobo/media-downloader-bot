require 'uri'

require_relative 'http_backend'

class Diarizer
  module SherpaOnnx
    mattr_accessor :api
    self.api = URI.parse(ENV.fetch('SHERPA_ONNX_SERVER', 'http://127.0.0.1:8083'))

    module_function

    def diarize(path, speakers: nil)
      HTTPBackend.diarize(api, path, speakers: speakers)
    end

    extend self
  end
end
