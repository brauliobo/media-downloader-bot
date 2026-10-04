class Translator

  BACKEND_CLASS = const_get ENV.fetch('TRANSLATOR', 'HyMT2').to_sym

  extend BACKEND_CLASS

  BATCH_SIZE = 50
  def self.translate_srt srt, to:, from: nil
    Subtitler::Subtitle.from_srt(srt)
      .translate_srt!(from: from, to: to, translator: self, batch_size: BATCH_SIZE)
      .to_srt
  end

end
