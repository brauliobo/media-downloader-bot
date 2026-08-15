class Subtitler
  TIMESTAMP_VALUE  = /(?:\d{1,2}:)?\d{2}:\d{2}[,.]\d{3}/.freeze
  TIMESTAMP        = /\A(?:(\d{1,2}):)?(\d{2}):(\d{2})(?:[\.,](\d{3}))?/.freeze
  INLINE_TIMESTAMP = /<(#{TIMESTAMP_VALUE})>/.freeze
  CUE_TIMING       = /\A\s*#{TIMESTAMP_VALUE}\s+-->\s+#{TIMESTAMP_VALUE}(?:\s+.*)?\s*\z/.freeze

  def self.parse_timestamp(timestamp)
    match = timestamp&.match(TIMESTAMP)
    return unless match && match[0].length == timestamp.length
    return if match[2].to_i >= 60 || match[3].to_i >= 60

    match[1].to_i * 3600 + match[2].to_i * 60 + match[3].to_i + match[4].to_i / 1000.0
  end

  def self.timestamp_units(seconds, precision: 3)
    (seconds.to_f * (10**precision)).round
  end

  def self.format_timestamp(seconds, decimal: '.', precision: 3, hour_digits: 2)
    scale = 10**precision
    total_units = timestamp_units(seconds, precision: precision)
    hours, remainder = total_units.divmod(3600 * scale)
    minutes, remainder = remainder.divmod(60 * scale)
    secs, fraction = remainder.divmod(scale)
    format("%0#{hour_digits}d:%02d:%02d#{decimal}%0#{precision}d", hours, minutes, secs, fraction)
  end
end
