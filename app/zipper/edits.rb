class Zipper
  # What the request asks to do to the media: speed, cuts, silences, rates and audio cleanup.
  module Edits
    protected

    def reduce_framerate
      fgraph << mpdecimate_filter if opts.mpdecimate
      fgraph << FFmpeg.decimate_filter if opts.nompdecimate
    end

    def mpdecimate_filter
      FFmpeg.decimate_filter opts.mpdecimate == 1 ? nil : opts.mpdecimate
    end

    def limit_framerate
      @output_frame_rate = opts.maxfr.to_i if opts.maxfr
    end

    def apply_audio_rate
      rate = opts.freq&.to_i || opts.ar&.to_i
      return unless rate

      @audio_sample_rate = rate
      require_audio_reencode
    end

    def apply_audio_channels
      return unless opts.ac

      @audio_channels = opts.ac.to_i
      require_audio_reencode
    end

    def apply_cut
      return unless Utils::Duration.cut?(opts)

      cut = Utils::Duration.from_opts(opts)
      @input_seek      = cut.start if opts.ss
      @output_end      = cut.finish if opts.to
      @output_duration = cut.duration if opts.t
    end

    def apply_speed
      return if opts.speed == 1

      fgraph << FFmpeg.speed_filter(opts.speed, stream: :video) if video?
      append_audio_filter FFmpeg.speed_filter(opts.speed, stream: :audio)
    end

    def apply_media_edits
      apply_silences
      apply_cuts
    end

    def apply_silences
      return if silences.empty? || !audio_stream?

      append_audio_filter FFmpeg.silence_filter silences
    end

    def apply_cuts
      return if cuts.empty?

      filters = FFmpeg.cut_filters cuts, video: video?, audio: audio_stream?
      fgraph.concat filters.fetch(:video)
      filters.fetch(:audio).each { |filter| append_audio_filter filter }
    end

    def apply_voice_quality
      append_audio_filter FFmpeg.voice_quality_filter if opts.voice_quality
    end

    def apply_speech_cleanup
      append_audio_filter FFmpeg.speech_cleanup_filter if opts.speech_cleanup
    end

    def append_audio_filter filter
      audio_filters << filter
      require_audio_reencode
    end

    def audio_reencode_required?
      @audio_reencode_required
    end

    def require_audio_reencode
      @audio_reencode_required = true
    end
  end
end
