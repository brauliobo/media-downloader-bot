require 'uri'

require_relative 'http_backend'

class VoiceSeparator
  module Spleeter
    extend HTTPBackend
    configure(env: 'SPLEETER_SERVER', port: 8086)
  end
end
