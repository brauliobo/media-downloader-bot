class TTS
  # A Reference made up by the backend, for when there is no recorded voice to clone, only an instruction such as
  # "female, middle-aged". Left alone each call would invent another voice, so one is synthesized once and every
  # later call clones it. Not for a recorded Reference, which is already the voice: a copy of that is
  # Dubbing::TargetVoice, made to speak another language.
  module Anchor
    module_function

    def call(text:, lang:, path:, **options)
      TTS.synthesize(text: text, lang: lang, out_path: path, **options) unless File.size?(path)
      Reference.new(path: path, text: text)
    end
  end
end
