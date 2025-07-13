require_relative 'tts/piper'
require_relative 'tts/coqui_tts'

class TTS
  BACKEND_CLASS = const_get(ENV['TTS'] || 'CoquiTTS')

  extend BACKEND_CLASS
end
