require 'uri'

class VoiceActivity
  module Silero
    mattr_accessor :api
    self.api = URI.parse(ENV.fetch('SILERO_VAD_SERVER', 'http://127.0.0.1:8089'))

    module_function

    def detect(path)
      HTTPBackend.detect(api, path)
    end

    extend self
  end
end
