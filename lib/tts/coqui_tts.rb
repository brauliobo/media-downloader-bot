require_relative 'http_backend'

class TTS
  module CoquiTTS
    include HTTPBackend

    configure_backend(
      base_url: "http://127.0.0.1:#{ENV['PORT']&.to_i || 10230}",
      segment_chars: 500,
      concurrency: ENV['COQUITTS_CONCURRENCY']&.to_i || 10*2
    )

    extend self
  end

end
