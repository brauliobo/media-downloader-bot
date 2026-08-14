class FFmpeg
  def extract_audio input:, output:, sample_rate:, channels:, label:, start: nil, duration: nil,
                    filter: nil, filter_profile: nil, silence_threshold_db: nil,
                    pad_duration: nil, codec: 'pcm_s16le'
    filter = FFmpeg.voice_reference_filter filter_profile,
                                           silence_threshold_db: silence_threshold_db,
                                           pad_duration: pad_duration if filter.nil? && filter_profile

    run_one_shot profile: :extract, label: label do |builder|
      builder.input input, seek: start, duration: duration
      builder.disable :video
      builder.add_filter filter, stream: :audio if filter
      builder.channels channels
      builder.sample_rate sample_rate
      builder.codec codec, stream: :audio
      builder.output output
    end
  end

  def transcribe_wav input:, output:, label:
    run_one_shot profile: :overwrite, label: label do |builder|
      builder.input input
      builder.sample_rate 16_000
      builder.channels 1
      builder.codec 'pcm_s16le', stream: :audio
      builder.output output
    end
  end

  def convert_subtitle input:, format:, label:, stream_index: nil
    run_one_shot label: label do |builder|
      builder.input input
      builder.map_stream :subtitle, index: stream_index unless stream_index.nil?
      builder.codec 'webvtt', stream: :subtitle if %i[vtt webvtt].include? format.to_sym
      builder.format format.to_sym == :vtt ? :webvtt : format
      builder.output :stdout
    end
  end

  def remux_audio input:, output:, label:
    run_one_shot profile: :overwrite, label: label do |builder|
      builder.input input
      builder.map_stream :audio
      builder.copy stream: :audio
      builder.movflags '+faststart'
      builder.format :mp4
      builder.output output
    end
  end

  def normalize_dub_audio input:, output:, label:
    run_one_shot label: label do |builder|
      builder.input input
      builder.channels 1
      builder.sample_rate 48_000
      builder.output output
    end
  end

  def render_dub_timeline output:, label:, inputs: nil, clips: nil, duration: nil, filter: nil
    inputs ||= clips.map(&:path)
    filter ||= FFmpeg.dub_timeline_filter clips: clips, duration: duration

    run_one_shot label: label do |builder|
      inputs.each { |input| builder.input input }
      builder.set_complex_filter filter
      builder.channels 1
      builder.sample_rate 48_000
      builder.output output
    end
  end

  def create_dub_silence output:, duration:, label:
    run_one_shot label: label do |builder|
      source = FFmpeg.silence_source sample_rate: 48_000, channel_layout: :mono
      builder.input source, format: :lavfi
      builder.duration duration.to_f
      builder.output output
    end
  end

  def mux_dubbed_audio video:, speech:, non_vocals:, output:, duration:, label:, filter: nil
    filter ||= FFmpeg.dub_audio_mix_filter duration: duration

    run_one_shot label: label do |builder|
      builder.input video
      builder.input speech
      builder.input non_vocals
      builder.set_complex_filter filter
      builder.map_stream :video
      builder.map_filter 'a'
      builder.duration duration
      builder.copy stream: :video
      builder.codec 'aac', stream: :audio
      builder.bitrate 128, stream: :audio
      builder.output output
    end
  end

  # With copy enabled, inputs is the concat demuxer manifest path. Otherwise it
  # is an ordered collection of media paths joined by the concat filter.
  def concat_audio inputs:, output:, copy:, sample_rate: nil, label:
    run_one_shot label: label do |builder|
      if copy
        manifest = inputs.respond_to?(:to_path) ? inputs.to_path : inputs
        unless manifest.is_a? String
          raise ArgumentError, 'copy concat requires a manifest path'
        end

        builder.input manifest, format: :concat, safe: false
        builder.copy
      else
        inputs.each { |input| builder.input input }
        labels = inputs.each_index.map { |index| "[#{index}:a]" }.join
        filter = "#{labels}concat=n=#{inputs.size}:v=0:a=1"
        filter << ",aresample=#{sample_rate.to_i}" if sample_rate
        filter << '[a]'
        builder.set_complex_filter filter
        builder.map_filter :a
      end
      builder.output output
    end
  end

  def create_silence output:, duration:, label:, source: nil, source_sample_rate: nil,
                     filter: nil, sample_rate: nil, channels: nil, channel_layout: nil,
                     codec: nil, codec_profile: nil, bitrate: nil, sample_format: nil,
                     amplitude: nil
    if source.nil?
      if amplitude && amplitude.to_f.positive?
        source = FFmpeg.noise_source amplitude: amplitude,
                                     sample_rate: source_sample_rate || sample_rate || 48_000
        filter ||= FFmpeg.lowpass_filter 6000
      else
        source = FFmpeg.silence_source sample_rate: source_sample_rate || sample_rate || 48_000,
                                         channel_layout: channel_layout || :mono
      end
    end

    run_one_shot label: label do |builder|
      builder.input source, format: :lavfi
      builder.add_filter filter, stream: :audio if filter
      builder.duration duration
      builder.sample_rate sample_rate if sample_rate
      builder.channels channels if channels
      builder.channel_layout channel_layout if channel_layout
      builder.codec codec, stream: :audio if codec
      builder.codec_profile codec_profile, stream: :audio if codec_profile
      builder.bitrate bitrate, stream: :audio, unit: :bit if bitrate
      builder.sample_format sample_format, stream: :audio if sample_format
      builder.output output
    end
  end

  def add_audio_floor input:, output:, sample_rate:, label:, source: nil, filter: nil,
                       amplitude: nil, loudness_lufs: nil
    source ||= FFmpeg.audio_floor_source amplitude: amplitude, sample_rate: sample_rate
    filter ||= FFmpeg.audio_floor_filter loudness_lufs: loudness_lufs

    run_one_shot label: label do |builder|
      builder.input input
      builder.input source, format: :lavfi
      builder.set_complex_filter filter
      builder.channels 1
      builder.sample_rate sample_rate
      builder.codec 'pcm_s16le', stream: :audio
      builder.output output
    end
  end

  def speed_audio input:, output:, label:, filter: nil, speed: nil
    filter ||= FFmpeg.speech_speed_filter speed

    run_one_shot label: label do |builder|
      builder.input input
      builder.set_filter filter, stream: :audio
      builder.codec 'pcm_s16le', stream: :audio
      builder.output output
    end
  end

  def audio_to_wav input:, output:, sample_rate: nil, channels: nil, label:
    run_one_shot label: label do |builder|
      builder.input input
      builder.channels channels if channels
      builder.sample_rate sample_rate if sample_rate
      builder.output output
    end
  end

  public :extract_audio, :transcribe_wav, :convert_subtitle, :remux_audio,
         :normalize_dub_audio, :render_dub_timeline, :create_dub_silence,
         :mux_dubbed_audio, :concat_audio, :create_silence, :add_audio_floor,
         :speed_audio, :audio_to_wav
end
