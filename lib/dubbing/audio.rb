require_relative '../utils/sh'
require_relative '../zipper'
require_relative 'timing_score'

module Dubbing
  module Audio
    Clip          = Data.define(:path, :start, :end)
    ScheduledClip = Data.define(:path, :start, :end, :speed)
    Timeline      = Data.define(:path, :clips, :score) do
      def initialize(path:, clips:, score: nil)
        super
      end
    end

    module_function

    def normalize(input, output)
      run!(
        'dub audio normalization',
        "#{Zipper::FFMPEG} -i #{Sh.escape(input)} -ac 1 -ar 48000 #{Sh.escape(output)}",
        output
      )
    end

    def render_timeline(clips, output, duration:)
      return Timeline.new(path: silence(output, duration), clips: [], score: TimingScore.call([], [])) if clips.empty?

      source_clips = clips
      clips        = schedule(source_clips, duration: duration)
      inputs       = clips.map { |clip| "-i #{Sh.escape(clip.path)}" }.join(' ')
      chains       = clips.map.with_index do |clip, idx|
        delay = (clip.start.to_f * 1000).round
        speed = clip.speed == 1.0 ? '' : "#{tempo_filter(clip.speed)},"
        "[#{idx}:a]#{speed}adelay=#{delay}:all=1[a#{idx}]"
      end
      mix_inputs = clips.each_index.map { |idx| "[a#{idx}]" }.join
      filter = "#{chains.join(';')};#{mix_inputs}amix=inputs=#{clips.size}:normalize=0," \
        "loudnorm=I=-18:TP=-1.5:LRA=7,atrim=0:#{duration}"
      command = "#{Zipper::FFMPEG} #{inputs} -filter_complex #{Sh.escape(filter)} " \
        "-ac 1 -ar 48000 #{Sh.escape(output)}"

      Timeline.new(
        path:  run!('dub timeline', command, output),
        clips: clips,
        score: TimingScore.call(source_clips, clips)
      )
    end

    def replace_video_audio(video, audio, output, duration:)
      command = "#{Zipper::FFMPEG} -i #{Sh.escape(video)} -i #{Sh.escape(audio)} " \
        "-map 0:v:0 -map 1:a:0 -t #{duration} -c:v copy -c:a aac -b:a 128k #{Sh.escape(output)}"
      run!('dub mux', command, output)
    end

    def schedule(clips, duration:)
      clip_durations = clips.map { |clip| Prober.for(clip.path).format.duration.to_f }
      speech_limits  = clips.map { |clip| speech_limit(clip, duration) }
      before, after  = gap_allowances(clips, clip_durations, speech_limits, duration)

      clips.each_with_index.map do |clip, idx|
        schedule_clip(clip, clip_durations[idx], speech_limits[idx], before[idx], after[idx])
      end
    end

    def gap_allowances(clips, clip_durations, speech_limits, duration)
      before    = Array.new(clips.size, 0.0)
      after     = Array.new(clips.size, 0.0)
      remaining = clip_durations.zip(speech_limits).map { |clip_duration, limit| positive(clip_duration - limit) }
      return [before, after] if clips.empty?

      claim_gap!(before, 0, positive(clips.first.start.to_f), remaining)
      clips.each_cons(2).with_index do |(left, right), idx|
        share_gap!(positive(right.start.to_f - left.end.to_f), idx, before, after, remaining)
      end
      claim_gap!(after, -1, positive(duration.to_f - clips.last.end.to_f), remaining)

      [before, after]
    end

    def share_gap!(gap, left_idx, before, after, remaining)
      right_idx  = left_idx + 1
      total_need = remaining[left_idx] + remaining[right_idx]
      return unless gap.positive? && total_need.positive?

      available = [gap, total_need].min
      left_gap  = available * remaining[left_idx] / total_need
      claim_gap!(after, left_idx, left_gap, remaining)
      claim_gap!(before, right_idx, available - left_gap, remaining)
    end

    def claim_gap!(allowances, idx, gap, remaining)
      allowances[idx] = [gap, remaining[idx]].min
      remaining[idx] -= allowances[idx]
    end

    def schedule_clip(clip, clip_duration, speech_limit, before, after)
      start     = clip.start.to_f - before
      speed     = fit_speed(clip_duration, speech_limit + before + after)
      finish    = start + clip_duration / speed

      ScheduledClip.new(path: clip.path, start: start, end: finish, speed: speed)
    end

    def positive(value)
      [value, 0.0].max
    end

    def fit_speed(duration, natural_limit)
      raise 'dubbed speech has no positive source interval' unless natural_limit.positive?
      return 1.0 if duration <= 0

      [duration / natural_limit, 1.0].max
    end

    def speech_limit(clip, duration)
      [clip.end.to_f, duration.to_f].min - clip.start.to_f
    end

    def tempo_filter(speed)
      remaining = speed.to_f
      factors = []
      while remaining < 0.5
        factors << 0.5
        remaining /= 0.5
      end
      while remaining > 2.0
        factors << 2.0
        remaining /= 2.0
      end
      factors << remaining unless remaining == 1.0
      factors.map { |factor| "atempo=#{format('%.6f', factor)}" }.join(',')
    end

    def silence(output, duration)
      command = "#{Zipper::FFMPEG} -f lavfi -i anullsrc=channel_layout=mono:sample_rate=48000 " \
        "-t #{duration.to_f} #{Sh.escape(output)}"
      run!('dub silence', command, output)
    end

    def run!(label, command, output)
      _, stderr, status = Sh.run(command)
      raise "#{label} failed: #{stderr}" unless status.success? && File.exist?(output)

      output
    end
  end
end
