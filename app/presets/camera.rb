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
      Float::INFINITY => {
        keyframes: 1,
        mpdecimate: 'hi=6144:lo=3072:frac=0.80',
        noaudio: 1,
      },
    }.freeze

    # Per tier, the kbit/s an average file converts to is far below (measured 6-57); a file already under it has nothing to gain.
    CEILING_KBIT = [100, 100, 100, 30].freeze

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

    # The tier is stamped into the output, so a later run only converts a file again once it reaches a stricter one.
    def self.tier(path)
      AGE_TIERS.values.fetch(tier_rank(path)).merge(mediazip_tier: tier_rank(path).to_s)
    end

    def self.tier_rank(path) = AGE_TIERS.keys.index { |max_age| age_days(path) <= max_age }

    def self.converted?(path)
      format = Prober.for(path).format
      tier = format&.tags&.comment.to_s[/\Amediazip:(\d+)\z/, 1]
      rank = tier_rank(path)
      (tier && tier.to_i >= rank) || (format.bit_rate.to_i.positive? && format.bit_rate.to_i / 1000 <= CEILING_KBIT.fetch(rank))
    rescue
      false
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
