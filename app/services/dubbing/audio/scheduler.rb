module Dubbing
  module Audio
    # Fits dubbed speech into its source slots: first by growing into the surrounding silence, then
    # by compressing up to the speaker's own pace, then by pushing the sentences ahead of it.
    class Scheduler
      # Seconds a sentence may be pushed away from its source slot instead of being compressed further.
      DRIFT_LIMIT = 1.5
      # Silence kept between consecutive sentences, the same one audiobooks leave between theirs.
      PAUSE = Audiobook::Pauses::SENTENCE

      def initialize(clips, duration:, ffmpeg:)
        @duration = duration.to_f
        @slots    = clips.map { |clip| build_slot(clip, ffmpeg) }
        @cursor   = 0.0
        assign_ceilings!
        assign_latest_ends!
      end

      def call
        allocate_gaps
        @slots.map { |slot| schedule_slot slot }
      end

      private

      def build_slot(clip, ffmpeg)
        span = SpeechSpan.detect(clip.path, ffmpeg: ffmpeg)
        Slot.new(
          clip, duration: span.speech, leading: span.leading, trailing: span.trailing, limit: @duration
        )
      end

      # A speaker may exceed the pace it already sustains by SpeechSpeed::TOLERANCE. The median
      # keeps mistranscribed slots from raising the ceiling for the whole speaker.
      def assign_ceilings!
        @slots.group_by { |slot| slot.clip.speaker_id }.each_value do |slots|
          ceiling = SpeechSpeed.ceiling Utils::Stats.median(slots.map(&:pace))
          slots.each { |slot| slot.ceiling = ceiling }
        end
      end

      # Latest end that still leaves every following sentence room to be rendered after its pause.
      def assign_latest_ends!
        @slots.reverse_each.inject(@duration) do |latest, slot|
          slot.latest = latest
          latest - slot.duration / SpeechSpeed::MAXIMUM - PAUSE
        end
      end

      def allocate_gaps
        return if @slots.empty?

        @slots.first.grow_start! @slots.first.clip.start.to_f.clamp(0.0..)
        @slots.each_cons(2) { |left, right| share_gap! left, right }
        @slots.last.grow_end! (@duration - @slots.last.clip.end.to_f).clamp(0.0..)
      end

      def share_gap!(left, right)
        gap        = (right.clip.start.to_f - left.clip.end.to_f - PAUSE).clamp(0.0..)
        total_need = left.remaining + right.remaining
        return unless gap.positive? && total_need.positive?

        available = [gap, total_need].min
        left_gap  = available * left.remaining / total_need
        left.grow_end! left_gap
        right.grow_start! available - left_gap
      end

      def schedule_slot(slot)
        window_start = [slot.lo, @cursor].max
        speed        = fit_speed(slot, window_start)
        rendered     = slot.duration / speed
        start        = position(slot, rendered, window_start)
        @cursor      = start + rendered + PAUSE

        slot.schedule start: start, rendered: rendered, speed: speed
      end

      # Compress only as far as the speaker's pace allows, then let the sentence push into the
      # silence and slack ahead of it; compress past the ceiling only when nothing else fits.
      def fit_speed(slot, window_start)
        return SpeechSpeed::NATURAL unless slot.duration.positive?

        hard_room = room(window_start, hard_end(slot))
        speed     = (slot.duration / room(window_start, slot.hi)).clamp(SpeechSpeed::NATURAL, slot.ceiling)
        return speed if slot.duration / speed <= hard_room

        (slot.duration / hard_room).clamp(SpeechSpeed::NATURAL, SpeechSpeed::MAXIMUM)
      end

      def position(slot, rendered, window_start)
        centered = slot.lo + (slot.span - rendered) / 2.0
        centered.clamp(window_start, [hard_end(slot) - rendered, window_start].max)
      end

      def room(window_start, finish) = (finish - window_start).clamp(0.0..)

      def hard_end(slot) = [slot.hi + DRIFT_LIMIT, slot.latest].min
    end
  end
end
