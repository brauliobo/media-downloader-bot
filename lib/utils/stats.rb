module Utils
  # Descriptive statistics over numeric samples. Every reduction of an empty sample is 0.0.
  module Stats
    module_function

    def mean(values) = values.empty? ? 0.0 : values.sum.fdiv(values.size)

    def rms(values) = Math.sqrt(mean(values.map { |value| value**2 }))

    def median(values)
      return 0.0 if values.empty?

      sorted = values.sort
      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def percentile(values, ratio)
      return 0.0 if values.empty?

      sorted = values.sort
      sorted[[(sorted.size * ratio).ceil - 1, 0].max]
    end
  end
end
