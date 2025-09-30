require_relative 'sentence'
require_relative '../zipper'

module Audiobook
  # Represents a heading - single sentence with extra pause
  class Heading < Sentence
    PAUSE = 0.5

    def to_h
      { 'heading' => { 'text' => text } }
    end

    # Generate audio with prepended pause (overrides Sentence#to_wav)
    def to_wav(dir, idx, lang: 'en', stl: nil, **_kwargs)
      wav = super(dir, idx, lang: lang)
      Zipper.prepend_silence!(wav, PAUSE, dir: dir) if wav
      wav
    end
  end
end
