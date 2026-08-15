class Subtitler
  TIMESTAMP_VALUE  = /(?:\d{1,2}:)?\d{2}:\d{2}[,.]\d{3}/.freeze
  TIMESTAMP        = /\A(?:(\d{1,2}):)?(\d{2}):(\d{2})(?:[\.,](\d{3}))?/.freeze
  INLINE_TIMESTAMP = /<(\d{2}:\d{2}:\d{2}[,.]\d{3})>/.freeze
  CUE_TIMING       = /\A\s*#{TIMESTAMP_VALUE}\s+-->\s+#{TIMESTAMP_VALUE}(?:\s+.*)?\s*\z/.freeze
end
