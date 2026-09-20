module Dubbing
  module Audio
    # Room reserved for one sentence: the window it may occupy, how much of its synthesized
    # speech does not fit in that window, and the pace its speaker sustains.
    class Slot
      attr_reader :clip, :duration, :lo, :hi, :remaining, :leading, :trailing
      attr_accessor :ceiling, :latest

      def initialize(clip, duration:, limit:, leading: 0.0, trailing: 0.0)
        @clip        = clip
        @duration    = duration
        @leading     = leading.to_f
        @trailing    = trailing.to_f
        @lo          = clip.start.to_f
        @hi          = [clip.end.to_f, limit].min
        @source_span = span
        @remaining   = (duration - @source_span).clamp(0.0..)
      end

      def span = @hi - @lo

      # How much longer the synthesized speech runs than the source speaker took to say it.
      def pace = @duration / @source_span.clamp(0.0..)

      def grow_start!(gap) = @lo -= claim!(gap)

      def grow_end!(gap) = @hi += claim!(gap)

      def schedule(start:, rendered:, speed:)
        ScheduledClip.new(
          path: @clip.path, start: start, end: start + rendered, speed: speed,
          leading: @leading, trailing: @trailing, speech: @duration
        )
      end

      private

      def claim!(gap)
        claimed     = [gap, @remaining].min
        @remaining -= claimed
        claimed
      end
    end
  end
end
