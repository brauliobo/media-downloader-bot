class Zipper
  # How the planned zip is put into the ffmpeg command: inputs, scale, maps, sizes, audio and metadata.
  module Command
    protected

    def video_input_opts
      options = {}
      options[:cuda] = true if opts.cudadec
      options[:keyframes_only] = true if opts.keyframes
      options
    end

    def video_filters_before_subtitle
      return fgraph unless @subtitle_burn_index

      fgraph.first @subtitle_burn_index
    end

    def video_filters_after_subtitle
      return [] unless @subtitle_burn_index

      fgraph.drop @subtitle_burn_index
    end

    def add_video_scale builder
      stream = Prober.video_stream(probe)
      modulus = format_name == :vp9 ? 8 : 2
      if opts.preserve_resolution
        builder.preserve_resolution_scale modulus: modulus unless stream.width % modulus == 0 && stream.height % modulus == 0
      else
        builder.scale width: opts.width, modulus: modulus
      end
    end

    def add_maps builder
      return maps.each { |selector| builder.add_map selector } if maps.present?
      return unless subtitle_input_path

      builder.map_stream :video
      builder.map_stream :audio if audio_stream? && !opts.noaudio && !opts.no_audio
      builder.map_stream :subtitle, input: 1
    end

    def apply_video_size builder, size
      return unless size

      builder.maxrate size.maxrate, stream: :video if size.maxrate
      builder.buffer_size size.bufsize if size.bufsize
      builder.rate_control size.rate_control, stream: :video if size.rate_control
      builder.bitrate size.bitrate, stream: :video if size.bitrate
    end

    def apply_video_audio builder
      codec, bitrate = video_audio_codec
      return builder.no_audio if codec == :none
      return builder.copy_audio if codec == :copy

      builder.encode_audio codec, bitrate: bitrate
    end

    def apply_metadata builder
      unless ENV['SKIP_META']
        builder.metadata_policy(
          tags: opts.metadata || {},
          mark: !(ENV['SKIP_METAMARK'] || opts.skip_metamark)
        )
      end
      builder.movflags '+faststart' if video?
    end

    def video_audio_codec
      return [:none, nil] if opts.noaudio || opts.no_audio
      return [:copy, nil] if opts.dub && !audio_reencode_required?

      requested = opts.acodec&.to_sym
      codec = if Formats::AUDIO_PROFILES.key? requested
        requested
      else
        :opus
      end
      opts.abrate ||= opts.format&.opts&.abrate || 64
      opts.abrate = (Formats::AUDIO_PROFILES[codec].fetch(:percent) * opts.abrate).round if size_mb_limit
      [codec, opts.abrate]
    end

    def add_audio_input_options builder
      builder.seek input_seek if input_seek
      builder.sample_rate audio_sample_rate if audio_sample_rate
      builder.channels audio_channels if audio_channels
    end

    def add_subtitle_stream builder
      return unless subtitle_input_path

      %i[language title].each { |key| builder.metadata key, subtitle_language, stream: :subtitle } if subtitle_language
      builder.subtitle_codec
    end

    def finish_command builder
      apply_metadata builder
      builder.end_at output_end if output_end
      builder.duration output_duration if output_duration
      builder.output outfile
      builder.capture
    end
  end
end
