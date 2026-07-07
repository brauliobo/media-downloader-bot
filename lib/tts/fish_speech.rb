require_relative 'http_backend'

class TTS
  module FishSpeech
    include HTTPBackend

    configure_backend(
      base_url:      "http://127.0.0.1:#{ENV['FISH_SPEECH_PORT']&.to_i || 10242}",
      segment_chars: ENV['FISH_SPEECH_SEGMENT_CHARS']&.to_i || 500,
      concurrency:   ENV['FISH_SPEECH_CONCURRENCY']&.to_i || 1
    )

    def self.output_sample_rate
      TTS.env_sample_rate('FISH_SPEECH_SAMPLE_RATE') || 44_100
    end

    extend self
  end
end
