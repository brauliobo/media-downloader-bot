require_relative 'range_list'

module Utils
  class TimeRanges
    Interval = Data.define(:start, :finish)
    TIME_PATTERN = /\A(?:\d+(?::\d{1,2}){0,2})(?:\.\d{1,3})?\z/

    attr_reader :intervals

    def self.parse(value, option:)
      spans = RangeList.parse(value, option: option, allow_single: false) { |part| timestamp(part) }
      new(Array(spans).map { |span| Interval.new(start: span.first, finish: span.last) }, option: option)
    end

    def self.timestamp(value)
      source = value.to_s
      raise ArgumentError unless source.match?(TIME_PATTERN)

      parts = source.split(':').map(&:to_f)
      raise ArgumentError if parts.size > 1 && parts.last >= 60
      raise ArgumentError if parts.size == 3 && parts[1] >= 60

      parts.reverse.each_with_index.sum { |part, index| part * (60**index) }
    end

    def initialize(intervals, option:)
      intervals.each { |interval| invalid!(option) unless interval.start < interval.finish }
      @option    = option
      @intervals = merge(intervals)
    end

    def empty? = intervals.empty?
    def total_duration = intervals.sum { |interval| interval.finish - interval.start }

    def validate!(duration, allow_entire: true)
      duration = duration.to_f
      invalid!(@option, 'interval exceeds media duration') if intervals.any? { |interval| interval.finish > duration }
      invalid!(@option, 'intervals remove the entire media') if !allow_entire && !empty? && total_duration >= duration
      self
    end

    private

    def merge(values)
      values.sort_by(&:start).each_with_object([]) do |interval, merged|
        previous = merged.last
        if previous && interval.start <= previous.finish
          merged[-1] = Interval.new(start: previous.start, finish: [previous.finish, interval.finish].max)
        else
          merged << interval
        end
      end
    end

    def invalid!(option, reason = 'intervals must have a positive duration')
      raise ArgumentError, "invalid #{option} option: #{reason}"
    end
  end
end
