require 'uri'

class VoiceSeparator
  module Demucs
    extend HTTPBackend
    configure(env: 'DEMUCS_SERVER', port: 8084)
  end
end
