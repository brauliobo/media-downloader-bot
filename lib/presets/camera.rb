module Presets
  class Camera
    DEFAULTS = {
      cuda: 1,
      format: 'h264',
      quality: 32,
      acodec: 'aac',
      abrate: 32,
      vf: 'mpdecimate=hi=1024:lo=512:frac=0.40',
      preserve_resolution: 1,
      delete_originals: 1,
    }.freeze

    def self.apply(opts, option_args: nil)
      DEFAULTS.each do |key, value|
        next if opts.key?(key)

        raw = value == 1 ? key.to_s : "#{key}=#{value}"
        option_args << raw if option_args
        Processors::Base.add_opt(opts, raw)
      end

      opts
    end
  end
end
