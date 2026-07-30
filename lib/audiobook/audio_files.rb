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

    def speed!(path, speed)
      Zipper.speed_audio_file!(path, speed)
    end

    def speed_all(paths, speed)
      Array(paths).each { |path| speed!(path, speed) }
    end

    def split_speed_options(options)
      options ||= {}
      [options[:audio_speed], options.except(:audio_speed)]
    end

    def sample_rate
      TTS.output_sample_rate
    end
  end
end
