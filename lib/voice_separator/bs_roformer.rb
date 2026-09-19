require 'uri'

require_relative 'http_backend'

class VoiceSeparator
  module BSRoformer
    extend HTTPBackend
    configure(env: 'BS_ROFORMER_SERVER', port: 8085)
  end
end
