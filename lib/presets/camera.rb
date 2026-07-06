require 'date'

module Presets
  class Camera
    DEFAULTS = {
      # mpdecimate is CPU-side; use NVENC but keep CPU decode to avoid GPU/CPU frame handoff stalls.
      cudaenc: 1,
      format: 'h264',
      quality: 32,
      acodec: 'aac',
      preserve_resolution: 1,
      delete_originals: 1,
    }.freeze

    AGE_TIERS = {
      30 => {
        vf: 'mpdecimate=hi=1024:lo=512:frac=0.40',
        abrate: 32,
      },
      60 => {
        vf: 'mpdecimate=hi=1536:lo=768:frac=0.45',
        abrate: 24,
      },
      90 => {
        vf: 'mpdecimate=hi=2048:lo=1024:frac=0.50',
        abrate: 16,
      },
      120 => {
        vf: 'mpdecimate=hi=3072:lo=1536:frac=0.60',
        abrate: 12,
      },
      180 => {
        vf: 'mpdecimate=hi=4096:lo=2048:frac=0.70',
        abrate: 12,
      },
      Float::INFINITY => {
        keyframes: 1,
        mpdecimate: 'hi=6144:lo=3072:frac=0.80',
        noaudio: 1,
      },
    }.freeze

    DATE_REGEX = /(\d{8})_\d{6}/

    def self.apply(opts, option_args: nil, path: nil)
      apply_options(opts, DEFAULTS, option_args: option_args)
      apply_options(opts, tier(path), option_args: option_args) if path
      opts
    end

    def self.tier_args(path, opts)
      tier(path).filter_map do |key, value|
        next if opts.key?(key)

        raw_option(key, value)
      end
    end

    def self.tier(path)
      AGE_TIERS.find { |max_age, _settings| age_days(path) <= max_age }.last
    end

    def self.age_days(path)
      match = ::File.basename(path.to_s).match(DATE_REGEX)
      return 0 unless match

      (Date.today - Date.strptime(match[1], '%Y%m%d')).to_i
    rescue Date::Error
      0
    end

    def self.apply_options(opts, settings, option_args: nil)
      settings.each do |key, value|
        next if opts.key?(key)

        raw = raw_option(key, value)
        option_args << raw if option_args
        Processors::Base.add_opt(opts, raw)
      end
    end

    def self.raw_option(key, value)
      value == 1 ? key.to_s : "#{key}=#{value}"
    end
  end
end
