require_relative 'tts/piper'
require_relative 'tts/coqui_tts'
require_relative 'tts/outetts'
require_relative 'tts/omni_voice'

class TTS
  BACKEND = const_get(ENV['TTS'] || 'OmniVoice')

  def self.synthesize(**args)
    BACKEND.synthesize(**args)
  end

  def self.supports?(feature)
    BACKEND.respond_to?(predicate = :"supports_#{feature}?") && BACKEND.public_send(predicate)
  end
end
