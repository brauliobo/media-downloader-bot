module Utils
  class Duration
    PERIOD       = /\A(?:\d+(?:\.\d+)?[hms])+\z/i
    PERIOD_TOKEN = /(\d+(?:\.\d+)?)([hms])/i
    UNITS        = {h: 3600.0, m: 60.0, s: 1.0}.freeze
    FIELD        = /\A\d*(?:\.\d{1,3})?\z/
    CUT_KEYS     = %i[ss to t].freeze
    Section      = Data.define(:start, :finish, :duration)

    attr_reader :raw, :seconds
    alias to_f seconds

    def initialize(raw)
      @raw, @seconds = raw, self.class.parse(raw)
    end

    def to_i = seconds.to_i
    def to_s = raw.to_s
    def zero? = seconds.zero?
    def present? = raw.present?
    def -(other) = seconds - coerce(other)
    def +(other) = seconds + coerce(other)

    def self.parse(value)
      return value.to_f if value.is_a?(Numeric)

      source = value.to_s.strip
      raise ArgumentError if source.empty?

      source.match?(PERIOD) ? parse_period(source) : parse_clock(source)
    end

    def self.parse!(value, option:)
      parse(value)
    rescue ArgumentError
      raise ArgumentError, "invalid #{option} option: #{value.inspect}"
    end

    def self.cut?(opts) = CUT_KEYS.any? { |key| opts[key] }

    def self.from_opts(opts) = section(ss: opts.ss, to: opts.to, t: opts.t)

    def self.clear_cut!(*targets)
      targets.each { |opts| CUT_KEYS.each { |key| opts[key] = nil if opts[key] } }
    end

    def self.section(ss: nil, to: nil, t: nil)
      raise ArgumentError, 'invalid t option: cannot combine with to' if set?(t) && set?(to)

      start    = set?(ss) ? parse!(ss, option: :ss) : 0.0
      duration = set?(t) ? parse!(t, option: :t) : nil
      finish   = set?(to) ? parse!(to, option: :to) : (duration && start + duration)
      Section.new(start: start, finish: finish, duration: duration)
    end

    def self.parse_clock(source)
      raise ArgumentError unless source.match?(/\d/) && source.count(':') <= 2

      parts = source.split(':', -1)
      raise ArgumentError if parts.size > 3 || !parts.all? { |part| part.match?(FIELD) }

      values = parts.map { |part| part.empty? ? 0.0 : part.to_f }
      raise ArgumentError if values.size > 1 && values.last >= 60
      raise ArgumentError if values.size == 3 && values[1] >= 60

      values.reverse.each_with_index.sum { |part, index| part * (60**index) }
    end
    private_class_method :parse_clock

    def self.parse_period(source)
      source.scan(PERIOD_TOKEN).sum { |amount, unit| amount.to_f * UNITS.fetch(unit.downcase.to_sym) }
    end
    private_class_method :parse_period

    def self.set?(value) = !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
    private_class_method :set?

    private

    def coerce(other) = other.is_a?(self.class) ? other.seconds : other.to_f
  end
end
