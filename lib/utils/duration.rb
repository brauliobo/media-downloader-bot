require 'chronic_duration'

module Utils
  class Duration
    attr_reader :raw

    def initialize(raw)
      @raw = raw.to_s
    end

    def seconds = ChronicDuration.parse(raw).to_i

    def to_i = seconds
    def to_s = raw
    def zero? = seconds.zero?
    def present? = raw.present?

    def -(other) = seconds - other.to_i
    def +(other) = seconds + other.to_i

    def self.parse(str) = new(str)
  end
end
