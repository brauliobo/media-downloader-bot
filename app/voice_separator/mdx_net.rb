require 'uri'

class VoiceSeparator
  module MDXNet
    extend HTTPBackend
    configure(env: 'MDX_SERVER', port: 8087)
  end
end
