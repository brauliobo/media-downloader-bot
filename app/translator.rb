class Translator

  BACKEND_CLASS = const_get ENV.fetch('TRANSLATOR', 'HyMT2').to_sym

  extend BACKEND_CLASS

  BATCH_SIZE = 50

  def self.progress(total, status, label = 'translating')
    Utils::ProgressCounter.new(total: total, status: status) { |done, all| "#{label} #{done}/#{all}" }
  end

  # The texts translated a batch at a time by the block, which gets the batch and returns its translations.
  def self.in_batches(texts, progress: nil, batch_size: nil)
    progress&.advance(0)
    texts.each_slice(batch_size || BATCH_SIZE).flat_map do |slice|
      Array(yield(slice)).tap { progress&.advance(slice.size) }
    end
  end

  def self.translate_srt srt, to:, from: nil
    Subtitler::Subtitle.from_srt(srt)
      .translate_srt!(from: from, to: to, translator: self, batch_size: BATCH_SIZE)
      .to_srt
  end

end
