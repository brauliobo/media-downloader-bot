require_relative 'tts/piper'
require_relative 'tts/coqui_tts'

class TTS
  backend_env = ENV['TTS']
  BACKEND_CLASS = const_get(backend_env || 'CoquiTTS')

  extend BACKEND_CLASS
end
