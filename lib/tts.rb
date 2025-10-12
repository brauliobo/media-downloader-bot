require_relative 'tts/piper'
require_relative 'tts/coqui_tts'
require_relative 'tts/outetts'

class TTS
  BACKEND = const_get(ENV['TTS'] || 'CoquiTTS')

  def self.synthesize(**args)
    BACKEND.synthesize(**args)
  end
end
