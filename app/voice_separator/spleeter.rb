require 'uri'

class VoiceSeparator
  module Spleeter
    extend HTTPBackend
    configure(env: 'SPLEETER_SERVER', port: 8086)
  end
end
