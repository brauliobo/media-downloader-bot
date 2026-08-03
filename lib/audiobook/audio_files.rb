require_relative '../tts'
require_relative '../zipper'

module Audiobook
  module AudioFiles
    module_function

    def pause(seconds, dir, sample_rate: self.sample_rate, extension: '.wav', format: nil, amplitude: nil)
      options = format ? format.to_h.transform_keys(&:to_sym) : {}
      options[:sample_rate] = sample_rate unless options[:sample_rate].to_i.positive?
      options[:extension] = extension unless extension == '.wav'
      options[:amplitude] = amplitude if amplitude.to_f.positive?
      Zipper.get_pause_file(seconds, dir, **options)
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
