module Presets
  class Camera
    DEFAULTS = {
      cuda: 1,
      format: 'h265',
      quality: 32,
      acodec: 'aac',
      abrate: 32,
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
