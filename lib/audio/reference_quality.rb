module Audio
  class ReferenceQuality
    COMPONENT_WEIGHTS = {
      estimated_snr:  30,
      noise_floor:    20,
      entropy:        10,
      zero_crossing:   5,
      bit_depth:       5,
      silence:        10,
      loudness:       10,
      loudness_range:  5,
      peak_headroom:   5,
    }.freeze

    GRADES = {
      80.. => 'excellent',
      65...80 => 'good',
      50...65 => 'fair',
      ...50 => 'poor',
    }.freeze

    def initialize(quality: Quality.new)
      @quality = quality
    end

    def report(path, metadata: {})
      metrics = quality.report(path)
      components = score_components(metrics)
      score = components.values.sum.round(2)
      {
        **metadata,
        path:       File.expand_path(path),
        score:      score,
        grade:      grade(score),
        accepted:   metrics.fetch(:accepted),
        components: components,
        metrics:    metrics,
      }
    end

    def rank(paths, metadata: nil)
      Array(paths).map do |path|
        values = metadata ? metadata.call(path) : {}
        report(path, metadata: values || {})
      end.sort_by { |result| [-result.fetch(:score), result.fetch(:path)] }
    end

    def score_components(metrics)
      {
        estimated_snr:  points(metrics.fetch(:estimated_snr_db), 8, 30, COMPONENT_WEIGHTS.fetch(:estimated_snr)),
        noise_floor:    points(metrics.fetch(:estimated_noise_floor_db), -20, -50, COMPONENT_WEIGHTS.fetch(:noise_floor)),
        entropy:        points(metrics.fetch(:entropy), 0.55, 0.9, COMPONENT_WEIGHTS.fetch(:entropy)),
        zero_crossing:  points(metrics.fetch(:zero_crossing_rate), 0.15, 0.02, COMPONENT_WEIGHTS.fetch(:zero_crossing)),
        bit_depth:      points(metrics.fetch(:bit_depth), 10, 16, COMPONENT_WEIGHTS.fetch(:bit_depth)),
        silence:        points(metrics.fetch(:silence_ratio), 0.35, 0.02, COMPONENT_WEIGHTS.fetch(:silence)),
        loudness:       centered_points(metrics.fetch(:integrated_lufs), -18, 15, COMPONENT_WEIGHTS.fetch(:loudness)),
        loudness_range: points(metrics.fetch(:loudness_range_lu), 15, 4, COMPONENT_WEIGHTS.fetch(:loudness_range)),
        peak_headroom:  points(metrics.fetch(:true_peak_db), -0.1, -3, COMPONENT_WEIGHTS.fetch(:peak_headroom)),
      }.transform_values { |value| value.round(2) }
    end

    def grade(score)
      GRADES.find { |range, _name| range.cover?(score) }.last
    end

    def self.signal_score(metrics)
      metrics.fetch(:entropy) - metrics.fetch(:zero_crossing_rate) * 2 - (metrics.fetch(:rms_db) + 20).abs / 20
    end

    private

    attr_reader :quality

    def points(value, poor, good, weight)
      ratio = (value - poor).fdiv(good - poor)
      [[ratio, 0].max, 1].min * weight
    end

    def centered_points(value, target, tolerance, weight)
      ratio = 1 - (value - target).abs.fdiv(tolerance)
      [[ratio, 0].max, 1].min * weight
    end
  end
end
