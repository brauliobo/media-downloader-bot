require 'uri'

require_relative 'http_backend'

class VoiceSeparator
  module MDXNet
    # 16-bit stereo 44.1 kHz WAV is ~10.6 MB/min per stem. 8 GiB covers ~12 h.
    MAX_STEM_BYTES = ENV.fetch('VOICE_SEPARATOR_MAX_STEM_BYTES', 8 * 1024 * 1024 * 1024).to_i
    STEM_NAMES = %w[vocals.wav no_vocals.wav].freeze

    mattr_accessor :api
    self.api = URI.parse(ENV.fetch('MDX_SERVER', 'http://127.0.0.1:8087'))

    extend HTTPBackend
  end
end
