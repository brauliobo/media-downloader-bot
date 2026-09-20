module Dubbing
  module Audio
    # Audible range of a synthesized sentence: OmniVoice (and other TTS) prepends
    # ~200ms of silence that is not speech and must not drive tempo or subtitles.
    SpeechSpan = Data.define(:duration, :leading, :trailing, :speech) do
      THRESHOLD_DB = -35.0
      MIN_SPEECH   = 0.05
      EDGE         = 0.02

      def self.detect(path, ffmpeg:)
        duration = ffmpeg.audio_duration(path).to_f
        return empty(duration) unless duration.positive?

        _, stderr = ffmpeg.analyze_audio(
          path, kind: :silence, silence_threshold_db: THRESHOLD_DB
        )
        parse(stderr.to_s, duration)
      end

      def self.parse(stderr, duration)
        duration = duration.to_f
        return empty(duration) unless duration.positive?

        starts = stderr.scan(/silence_start:\s*(-?\d+(?:\.\d+)?)/).flatten.map(&:to_f)
        ends   = stderr.scan(/silence_end:\s*(-?\d+(?:\.\d+)?)/).flatten.map(&:to_f)

        leading = 0.0
        if starts.first && starts.first <= EDGE
          leading = (ends.first || duration).clamp(0.0, duration)
        end

        trailing = 0.0
        if starts.last
          open_at_end = ends.size < starts.size
          ends_at_eof = ends.last && (duration - ends.last).abs <= 0.05
          trailing = (duration - starts.last).clamp(0.0, duration) if open_at_end || ends_at_eof
        end

        speech = (duration - leading - trailing).clamp(0.0, duration)
        return empty(duration) if speech < MIN_SPEECH || leading + trailing >= duration

        new(duration: duration, leading: leading, trailing: trailing, speech: speech)
      end

      def self.empty(duration)
        value = duration.to_f
        new(duration: value, leading: 0.0, trailing: 0.0, speech: value)
      end
      private_class_method :empty
    end
  end
end
