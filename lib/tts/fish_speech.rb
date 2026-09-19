require_relative 'http_backend'

class TTS
  module FishSpeech
    include HTTPBackend

    configure_backend(
      base_url:      "http://127.0.0.1:#{ENV['FISH_SPEECH_PORT']&.to_i || 10242}",
      segment_chars: ENV['FISH_SPEECH_SEGMENT_CHARS']&.to_i || 500,
      sample_rate:     44_100,
      sample_rate_env: 'FISH_SPEECH_SAMPLE_RATE'
    )

    extend self
  end
end
