module Dubbing
  module TimingScore
    VERSION = 1

    module_function

    def call(expected, scheduled)
      pairs = Array(expected).zip(Array(scheduled))
      speeds = pairs.map { |_source, clip| clip.speed.to_f }
      tempo_deviations = speeds.map { |speed| Math.log2(speed).abs }
      sentences = pairs.map.with_index do |(source, clip), index|
        {
          index:           index + 1,
          start:           source.start.to_f,
          end:             source.end.to_f,
          speed:           clip.speed.to_f,
          deviation:       tempo_deviations.fetch(index) * 100,
        }
      end
      slot_errors = pairs.flat_map do |source, clip|
        [clip.start.to_f - source.start.to_f, clip.end.to_f - source.end.to_f]
      end

      {
        version:                    VERSION,
        sentence_count:             pairs.size,
        deviation_index:            rms(tempo_deviations) * 100,
        slot_deviation_ms:           rms(slot_errors) * 1000,
        tempo_deviation_mean:        mean(tempo_deviations) * 100,
        tempo_deviation_p90:         percentile(tempo_deviations, 0.9) * 100,
        speed_min:                   speeds.min,
        speed_p10:                   percentile(speeds, 0.1),
        speed_median:                percentile(speeds, 0.5),
        speed_p90:                   percentile(speeds, 0.9),
        speed_max:                   speeds.max,
        worst_sentences:             sentences.max_by(10) { |sentence| sentence.fetch(:deviation) },
      }
    end

    def mean(values)
      values.empty? ? 0.0 : values.sum.fdiv(values.size)
    end

    def rms(values)
      Math.sqrt(mean(values.map { |value| value**2 }))
    end

    def percentile(values, ratio)
      return 0.0 if values.empty?

      sorted = values.sort
      sorted[[(sorted.size * ratio).ceil - 1, 0].max]
    end
  end
end
