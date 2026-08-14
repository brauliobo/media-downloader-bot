require_relative '../ffmpeg'
require_relative '../prober'
require_relative 'timing_score'

module Dubbing
  module Audio
    module SpeechSpeed
      NATURAL = 1.0

      def self.validate!(value)
        speed = value.to_f
        raise ArgumentError, 'dubbed speech speed cannot be below 1x' if speed < NATURAL

        speed
      end
    end
    private_constant :SpeechSpeed

    Clip = Data.define(:path, :start, :end)
    ScheduledClip = Data.define(:path, :start, :end, :speed) do
      def initialize(**attributes)
        speed = SpeechSpeed.validate!(attributes.fetch(:speed))
        super(**attributes.merge(speed: speed))
      end
    end
    Timeline      = Data.define(:path, :clips, :score) do
      def initialize(path:, clips:, score: nil)
        super
      end
    end

    class Scheduler
      def initialize(clips, duration:, ffmpeg:)
        @clips          = clips
        @duration       = duration.to_f
        @clip_durations = clips.map { |clip| Prober.for(clip.path, ffmpeg: ffmpeg).format.duration.to_f }
        @speech_limits  = clips.map { |clip| speech_limit(clip) }
        @remaining      = @clip_durations.zip(@speech_limits).map { |clip_duration, limit| positive(clip_duration - limit) }
        @before         = Array.new(clips.size, 0.0)
        @after          = Array.new(clips.size, 0.0)
      end

      def call
        allocate_gaps
        @clips.each_index.map { |idx| schedule_clip(idx) }
      end

      private

      def allocate_gaps
        return if @clips.empty?

        claim_gap!(@before, 0, positive(@clips.first.start.to_f))
        @clips.each_cons(2).with_index do |(left, right), idx|
          share_gap!(positive(right.start.to_f - left.end.to_f), idx)
        end
        claim_gap!(@after, -1, positive(@duration - @clips.last.end.to_f))
      end

      def share_gap!(gap, left_idx)
        right_idx  = left_idx + 1
        total_need = @remaining[left_idx] + @remaining[right_idx]
        return unless gap.positive? && total_need.positive?

        available = [gap, total_need].min
        left_gap  = available * @remaining[left_idx] / total_need
        claim_gap!(@after, left_idx, left_gap)
        claim_gap!(@before, right_idx, available - left_gap)
      end

      def claim_gap!(allowances, idx, gap)
        allowances[idx] = [gap, @remaining[idx]].min
        @remaining[idx] -= allowances[idx]
      end

      def schedule_clip(idx)
        clip          = @clips[idx]
        clip_duration = @clip_durations[idx]
        start         = clip.start.to_f - @before[idx]
        available     = @speech_limits[idx] + @before[idx] + @after[idx]
        speed         = fit_speed(clip_duration, available)
        finish        = start + clip_duration / speed

        ScheduledClip.new(path: clip.path, start: start, end: finish, speed: speed)
      end

      def fit_speed(duration, available)
        raise 'dubbed speech has no positive source interval' unless available.positive?
        return SpeechSpeed::NATURAL if duration <= 0

        [duration / available, SpeechSpeed::NATURAL].max
      end

      def speech_limit(clip)
        [clip.end.to_f, @duration].min - clip.start.to_f
      end

      def positive(value)
        [value, 0.0].max
      end
    end
    private_constant :Scheduler

    module_function

    def normalize(input, output, ffmpeg: FFmpeg.new)
      ffmpeg.normalize_dub_audio(
        input: input, output: output, label: 'dub audio normalization'
      )
    end

    def render_timeline(clips, output, duration:, ffmpeg: FFmpeg.new)
      if clips.empty?
        return Timeline.new(
          path: silence(output, duration, ffmpeg: ffmpeg), clips: [],
          score: TimingScore.call([], [])
        )
      end

      source_clips = clips
      clips        = schedule(source_clips, duration: duration, ffmpeg: ffmpeg)
      filter = FFmpeg.dub_timeline_filter clips: clips, duration: duration

      Timeline.new(
        path:  ffmpeg.render_dub_timeline(
          inputs: clips.map(&:path), output: output, filter: filter, label: 'dub timeline'
        ),
        clips: clips,
        score: TimingScore.call(source_clips, clips)
      )
    end

    def replace_video_audio(video, speech, non_vocals, output, duration:, ffmpeg: FFmpeg.new)
      filter = FFmpeg.dub_audio_mix_filter duration: duration
      ffmpeg.mux_dubbed_audio(
        video: video, speech: speech, non_vocals: non_vocals, output: output,
        duration: duration, filter: filter, label: 'dub mux'
      )
    end

    def schedule(clips, duration:, ffmpeg: FFmpeg.new)
      Scheduler.new(clips, duration: duration, ffmpeg: ffmpeg).call
    end

    def tempo_filter(speed)
      remaining = SpeechSpeed.validate!(speed)
      factors = []
      while remaining > 2.0
        factors << 2.0
        remaining /= 2.0
      end
      factors << remaining unless remaining == 1.0
      factors.map { |factor| FFmpeg.speed_filter(format('%.6f', factor), stream: :audio) }.join ','
    end

    def silence(output, duration, ffmpeg: FFmpeg.new)
      ffmpeg.create_dub_silence output: output, duration: duration, label: 'dub silence'
    end
  end
end
