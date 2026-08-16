require_relative 'translator/nllb_serve'
require_relative 'translator/ollama'
require_relative 'translator/llamacpp_api'
require_relative 'translator/hymt2'
require_relative 'translator/madlad400'
require_relative 'subtitler/timestamps'
require_relative 'subtitler/subtitle'
require_relative 'subtitler/vtt'

class Translator

  BACKEND_CLASS = const_get ENV.fetch('TRANSLATOR', 'HyMT2').to_sym

  extend BACKEND_CLASS

  BATCH_SIZE = 50
  def self.translate_srt srt, to:, from: nil
    Subtitler::Subtitle.from_srt(srt)
      .translate_srt!(from: from, to: to, translator: self, batch_size: BATCH_SIZE)
      .to_srt
  end

  def self.translate_vtt vtt, to:, from: nil
    Subtitler::VTT.translate(vtt, to: to, from: from)
  end

end
