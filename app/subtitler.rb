class Subtitler
  STATUS_DETECTING    = 'detecting voice'
  STATUS_TRANSCRIBING = 'transcribing'

  BACKEND_CLASS = const_get ENV['SUBTITLER'].to_sym if ENV['SUBTITLER']

  extend Timestamps
  extend BACKEND_CLASS

  # Mixed soundtrack (subtitling): Silero VAD, then Whisper.
  def self.transcribe(path, stl: nil, **options)
    stl&.update STATUS_DETECTING
    VoiceActivity.with_speech(path) do |speech, ranges|
      next Subtitle.new if speech.nil?

      stl&.update STATUS_TRANSCRIBING
      VoiceActivity.restore_timing!(transcribe_vocals(speech, **options), ranges)
    end
  end

  # Isolated vocals (after Demucs): Whisper only.
  def self.transcribe_vocals(path, **options)
    transcribe_with_backend(path, **options)
  end

  def self.transcribe_with_backend(path, **options)
    BACKEND_CLASS.instance_method(:transcribe).bind_call(self, path, **options)
  end
  private_class_method :transcribe_with_backend
end
