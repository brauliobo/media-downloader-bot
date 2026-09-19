require 'uri'

require_relative 'http_backend'

class VoiceSeparator
  module MDXNet
    extend HTTPBackend
    configure(env: 'MDX_SERVER', port: 8087)
  end
end
