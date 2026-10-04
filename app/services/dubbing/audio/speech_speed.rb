module Dubbing
  module Audio
    module SpeechSpeed
      NATURAL = 1.0
      # Beyond 2x atempo the dubbed voice stops being intelligible, so it is the last resort.
      MAXIMUM = 2.0
      # How far a sentence may run past the pace its own speaker already sustains.
      TOLERANCE = 1.15

      def self.validate!(value)
        speed = value.to_f
        raise ArgumentError, 'dubbed speech speed cannot be below 1x' if speed < NATURAL

        speed
      end

      def self.ceiling(pace) = (pace * TOLERANCE).clamp(NATURAL, MAXIMUM)
    end
  end
end
