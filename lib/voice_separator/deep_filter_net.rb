require 'uri'

require_relative 'http_backend'

class VoiceSeparator
  module DeepFilterNet
    extend HTTPBackend
    configure(env: 'DEEPFILTER_SERVER', port: 8088)
  end
end
