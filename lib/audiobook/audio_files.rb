require_relative '../tts'
require_relative '../zipper'

module Audiobook
  module AudioFiles
    module_function

    def pause(seconds, dir)
      Zipper.get_pause_file(seconds, dir, sample_rate: sample_rate)
    end

    def silence(path, seconds)
      Zipper.silence_file(path, seconds, sample_rate: sample_rate)
    end

    def sample_rate
      TTS.output_sample_rate
    end
  end
end
