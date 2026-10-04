module Dubbing
  module Audio
    private_constant :Scheduler, :SpeechSpeed

    module_function

    def normalize(input, output, ffmpeg: FFmpeg.new)
      ffmpeg.normalize_dub_audio input: input, output: output, label: 'dub audio normalization'
    end

    def render_timeline(clips, output, duration:, ffmpeg: FFmpeg.new)
      return silent_timeline(output, duration, ffmpeg) if clips.empty?

      scheduled = schedule(clips, duration: duration, ffmpeg: ffmpeg)
      path      = ffmpeg.render_dub_timeline clips: scheduled, duration: duration, output: output, label: 'dub timeline'

      Timeline.new path: path, clips: scheduled, score: TimingScore.call(clips, scheduled)
    end

    def silent_timeline(output, duration, ffmpeg)
      Timeline.new path: silence(output, duration, ffmpeg: ffmpeg), clips: [], score: TimingScore.call([], [])
    end

    def replace_video_audio(video, speech, non_vocals, output, duration:, ffmpeg: FFmpeg.new)
      ffmpeg.mux_dubbed_audio(
        video: video, speech: speech, non_vocals: non_vocals, output: output,
        duration: duration, filter: FFmpeg.dub_audio_mix_filter(duration: duration), label: 'dub mux'
      )
    end

    def schedule(clips, duration:, ffmpeg: FFmpeg.new)
      Scheduler.new(clips, duration: duration, ffmpeg: ffmpeg).call
    end

    def tempo_filter(speed)
      remaining = SpeechSpeed.validate! speed
      factors   = []
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
