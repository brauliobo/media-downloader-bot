require 'uri'

require_relative 'http_backend'

class VoiceSeparator
  module Demucs
    extend HTTPBackend
    configure(env: 'DEMUCS_SERVER', port: 8084)
  end
end
