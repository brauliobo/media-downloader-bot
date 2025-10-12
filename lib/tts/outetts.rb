require_relative 'http_backend'

class TTS
  module OuteTTS
    include HTTPBackend

    configure_backend(
      base_url: "http://127.0.0.1:#{ENV['OUTETTS_PORT']&.to_i || 10330}",
      segment_chars: 500,
      concurrency: ENV['OUTETTS_CONCURRENCY']&.to_i || 10
    )

    extend self
  end
end
