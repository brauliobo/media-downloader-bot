class TTS
  # A Reference made up by the backend, for when there is no recorded voice to clone, only an instruction such as
  # "female, middle-aged". Left alone each call would invent another voice, so one is synthesized once and every
  # later call clones it. Never use it when a recorded Reference exists: that is already the voice, and cloning a
  # synthesized copy of it only loses fidelity.
  module Anchor
    module_function

    def call(text:, lang:, path:, **options)
      TTS.synthesize(text: text, lang: lang, out_path: path, **options) unless File.size?(path)
      Reference.new(path: path, text: text)
    end
  end
end
