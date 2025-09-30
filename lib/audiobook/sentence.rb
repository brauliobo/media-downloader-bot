require_relative 'speech'
require_relative '../tts'

module Audiobook
  # Represents a sentence of text to speak.
  class Sentence < Speech
    PAUSE = 0.10

    attr_reader :text

    def initialize(text)
      super()
      @text = text.to_s
        .gsub(/[\u0000-\u001F\u007F-\u009F]/, '') # control chars
        .tr("\x01\x02\x03\x04\x05\x06\x07\x08", '')
        .gsub(/\u00AD/, '')
        .gsub(/\s+/, ' ').strip
    end

    protected

    def synthesize_audio(wav_path, lang)
      if text.empty?
        super # generate silence
      else
        TTS.synthesize(text: text, lang: lang, out_path: wav_path)
      end
    end

    def extra_hash
      { 'text' => text }
    end
  end
end
