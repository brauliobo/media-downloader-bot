class Subtitler
  TIMESTAMP_VALUE  = /(?:\d{1,2}:)?\d{2}:\d{2}[,.]\d{3}/.freeze
  TIMESTAMP        = /\A(?:(\d{1,2}):)?(\d{2}):(\d{2})(?:[\.,](\d{3}))?/.freeze
  INLINE_TIMESTAMP = /<(#{TIMESTAMP_VALUE})>/.freeze
  CUE_TIMING       = /\A\s*#{TIMESTAMP_VALUE}\s+-->\s+#{TIMESTAMP_VALUE}(?:\s+.*)?\s*\z/.freeze

  def self.format_timestamp(seconds, decimal: '.')
    total_ms = (seconds.to_f * 1000).round
    hours, remainder = total_ms.divmod(3_600_000)
    minutes, remainder = remainder.divmod(60_000)
    secs, milliseconds = remainder.divmod(1000)
    format("%02d:%02d:%02d#{decimal}%03d", hours, minutes, secs, milliseconds)
  end
end
