require 'uri'

class VoiceSeparator
  module DeepFilterNet
    extend HTTPBackend
    configure(env: 'DEEPFILTER_SERVER', port: 8088)
  end
end
