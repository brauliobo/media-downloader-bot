require_relative 'sentence'

module Audiobook
  # Represents a heading - single sentence with extra pause
  class Heading
    PAUSE = 0.5

    attr_reader :sentence

    def initialize(text)
      @sentence = Sentence.new(text)
    end

    def text
      sentence.text
    end

    def to_h
      { 'heading' => { 'text' => text } }
    end

    # Generate audio for heading (just delegates to sentence with prepended pause)
    def to_wav(dir, idx, lang: 'en', stl: nil)
      wav = sentence.to_wav(dir, idx, lang: lang)
      Zipper.prepend_silence!(wav, PAUSE, dir: dir)
      wav
    end
  end
end
