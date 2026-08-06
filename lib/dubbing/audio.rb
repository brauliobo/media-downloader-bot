require_relative '../utils/sh'
require_relative '../zipper'

module Dubbing
  module Audio
    Clip          = Data.define(:path, :start, :end)
    ScheduledClip = Data.define(:path, :start, :end, :speed)
    Timeline      = Data.define(:path, :clips)

    module_function

    def normalize(input, output)
      run!(
        'dub audio normalization',
        "#{Zipper::FFMPEG} -i #{Sh.escape(input)} -ac 1 -ar 48000 #{Sh.escape(output)}",
        output
      )
    end

    def render_timeline(clips, output, duration:)
      return Timeline.new(path: silence(output, duration), clips: []) if clips.empty?

      clips = schedule(clips, duration: duration)
      inputs = clips.map { |clip| "-i #{Sh.escape(clip.path)}" }.join(' ')
      chains = clips.map.with_index do |clip, idx|
        delay = (clip.start.to_f * 1000).round
        speed = clip.speed == 1.0 ? '' : "#{tempo_filter(clip.speed)},"
        "[#{idx}:a]#{speed}adelay=#{delay}:all=1[a#{idx}]"
      end
      mix_inputs = clips.each_index.map { |idx| "[a#{idx}]" }.join
      filter = "#{chains.join(';')};#{mix_inputs}amix=inputs=#{clips.size}:normalize=0," \
        "loudnorm=I=-18:TP=-1.5:LRA=7,atrim=0:#{duration}"
      command = "#{Zipper::FFMPEG} #{inputs} -filter_complex #{Sh.escape(filter)} " \
        "-ac 1 -ar 48000 #{Sh.escape(output)}"

      Timeline.new(path: run!('dub timeline', command, output), clips: clips)
    end

    def replace_video_audio(video, audio, output, duration:)
      command = "#{Zipper::FFMPEG} -i #{Sh.escape(video)} -i #{Sh.escape(audio)} " \
        "-map 0:v:0 -map 1:a:0 -t #{duration} -c:v copy -c:a aac -b:a 128k #{Sh.escape(output)}"
      run!('dub mux', command, output)
    end

    def schedule(clips, duration:)
      clips.map.with_index do |clip, idx|
        start         = clip.start.to_f
        clip_duration = Prober.for(clip.path).format.duration.to_f
        natural_limit = speech_limit(clip, clips[idx + 1], duration)
        speed         = fit_speed(clip_duration, natural_limit)
        finish = start + clip_duration / speed

        ScheduledClip.new(path: clip.path, start: start, end: finish, speed: speed)
      end
    end

    def fit_speed(duration, natural_limit)
      raise 'dubbed speech has no positive source interval' unless natural_limit.positive?
      return 1.0 if duration <= 0

      [duration / natural_limit, 1.0].max
    end

    def speech_limit(clip, next_clip, duration)
      next_boundary = next_clip&.start&.to_f || duration.to_f
      [clip.end.to_f, next_boundary].min - clip.start.to_f
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
