class FFmpeg
  def input source, format: nil, safe: nil, seek: nil, duration: nil, sample_rate: nil,
            channels: nil, channel_layout: nil, cuda: false, keyframes_only: false
    arguments = []
    arguments.concat ['-hwaccel', 'cuda'] if cuda
    arguments.concat ['-skip_frame', 'nokey'] if keyframes_only
    arguments.concat ['-f', format.to_s] if format
    arguments.concat ['-safe', boolean_value(safe)] unless safe.nil?
    arguments.concat ['-ss', seek.to_s] unless seek.nil?
    arguments.concat ['-t', duration.to_s] unless duration.nil?
    arguments.concat ['-ar', sample_rate.to_i.to_s] unless sample_rate.nil?
    arguments.concat ['-ac', channels.to_i.to_s] unless channels.nil?
    arguments.concat ['-channel_layout', channel_layout.to_s] if channel_layout
    @inputs << [*arguments, '-i', source.to_s]
    self
  end

  def seek value
    set_operation [:seek], '-ss', value
  end

  def duration value
    set_operation [:duration], '-t', value
  end

  def end_at value
    set_operation [:end_at], '-to', value
  end

  def add_filter expression, stream:
    stream = stream_name stream
    @filters[stream] << expression.to_s
    add_filter_operation stream
    self
  end

  def preserve_resolution_scale modulus: 2
    add_filter FFmpeg.preserve_resolution_scale_filter(modulus: modulus), stream: :video
  end

  def decimate settings = nil
    add_filter FFmpeg.decimate_filter(settings), stream: :video
  end

  def speed_video value
    add_filter FFmpeg.speed_filter(value, stream: :video), stream: :video
  end

  def speed_audio_filter value
    add_filter FFmpeg.speed_filter(value, stream: :audio), stream: :audio
  end

  def speed value, stream:
    stream_name(stream) == 'v' ? speed_video(value) : speed_audio_filter(value)
  end

  def select_intervals expression, stream:, negate: false
    stream     = stream_name stream
    expression = "not(#{expression})" if negate
    filter     = stream == 'v' ? 'select' : 'aselect'
    timestamps = stream == 'v' ? 'setpts=N/FRAME_RATE/TB' : 'asetpts=N/SR/TB'
    add_filter "#{filter}='#{expression}'", stream: stream
    add_filter timestamps, stream: stream
  end

  def cut_intervals expression, video:, audio:
    select_intervals expression, stream: :video, negate: true if video
    select_intervals expression, stream: :audio, negate: true if audio
    self
  end

  def silence_intervals expression
    add_filter "volume=0:enable='#{expression}'", stream: :audio
  end

  def set_filter expression, stream:
    stream = stream_name stream
    @filters[stream] = [expression.to_s]
    add_filter_operation stream
    self
  end

  def clear_filters stream = nil
    streams = stream ? [stream_name(stream)] : @filters.keys
    streams.each do |name|
      @filters.delete name
      @operations.reject! { |operation| operation[:key] == [:filter, name] }
    end
    self
  end

  def set_complex_filter expression
    set_operation [:complex_filter], '-filter_complex', expression
  end

  def add_map selector
    add_operation '-map', selector
  end

  def map_stream stream, input: 0, index: 0
    add_map "#{input}:#{stream_name stream}:#{index}"
  end

  def map_filter label
    label = label.to_s
    add_map label.start_with?('[') ? label : "[#{label}]"
  end

  def codec name, stream: nil
    set_operation [:codec, stream_name(stream)], option_name('c', stream), name
  end

  def subtitle_codec
    codec SUBTITLE_CODEC, stream: :subtitle
  end

  def copy stream: nil
    codec 'copy', stream: stream
  end

  def copy_audio
    copy stream: :audio
  end

  def no_audio
    disable :audio
  end

  def disable stream
    key = [:disable, stream_name(stream)]
    flag = {
      'a' => '-an',
      'v' => '-vn',
      's' => '-sn',
      'd' => '-dn'
    }.fetch stream_name(stream)
    if @inputs.empty?
      set_global key, flag
    else
      set_operation key, flag
    end
  end

  def bitrate value, stream:, unit: :kbit
    stream = stream_name stream
    set_operation [:bitrate, stream], option_name('b', stream), rate_value(value, unit)
  end

  def sample_rate value, stream: nil
    set_operation [:sample_rate, stream_name(stream)], option_name('ar', stream), value.to_i
  end

  def frame_rate value, stream: nil
    set_operation [:frame_rate, stream_name(stream)], option_name('r', stream), value
  end

  def output_frame_rate value
    frame_rate value
  end

  def frame_rate_mode value, stream: nil
    set_operation [:frame_rate_mode, stream_name(stream)], option_name('fps_mode', stream), value
  end

  def channels value, stream: nil
    set_operation [:channels, stream_name(stream)], option_name('ac', stream), value.to_i
  end

  def output_sample_rate value
    sample_rate value
  end

  def output_channels value
    channels value
  end

  def channel_layout value, stream: nil
    set_operation [:channel_layout, stream_name(stream)], option_name('channel_layout', stream), value
  end

  def sample_format value, stream: nil
    set_operation [:sample_format, stream_name(stream)], option_name('sample_fmt', stream), value
  end

  def codec_profile name, stream:
    stream = stream_name stream
    set_operation [:codec_profile, stream], option_name('profile', stream), name
  end

  def average_bitrate enabled = true
    set_operation [:average_bitrate], '-abr', boolean_value(enabled)
  end

  def encode_video format, cuda:, quality:, preset: nil
    encoder = VIDEO_ENCODERS.fetch format.to_sym
    mode    = cuda ? :cuda : :cpu
    codec   = encoder[:"codec_#{mode}"] || encoder.fetch(:codec_cpu)
    qmode   = encoder[:"quality_#{mode}"] || encoder[:quality_cpu]
    preset ||= encoder[:"preset_#{mode}"]

    self.cuda encode: cuda
    self.codec codec, stream: :video
    self.quality quality, mode: qmode if qmode && !quality.nil?
    self.preset preset if preset
    return self unless cuda

    tune encoder[:tune_cuda] if encoder[:tune_cuda]
    multipass encoder[:multipass_cuda] if encoder[:multipass_cuda]
    adaptive_quantization if encoder[:aq_cuda]
    lookahead encoder[:lookahead_cuda] if encoder[:lookahead_cuda]
    bitrate encoder[:bitrate_cuda], stream: :video, unit: :bit if encoder.key? :bitrate_cuda
    self
  end

  def encode_audio format, bitrate:
    encoder = AUDIO_ENCODERS.fetch format.to_sym
    use_fdk = format.to_sym == :aac && @fdk_aac

    channels encoder[:channels] if encoder[:channels]
    sample_rate encoder[:sample_rate] if encoder[:sample_rate]
    codec(use_fdk ? encoder.fetch(:codec_fdk) : encoder.fetch(:codec), stream: :audio)
    codec_profile encoder.fetch(:profile_fdk), stream: :audio if use_fdk
    average_bitrate if encoder[:abr]
    self.bitrate bitrate, stream: :audio
  end

  def metadata key = nil, value = nil, stream: nil, index: nil, **entries
    unless entries.empty?
      entries.each_pair { |name, content| metadata name, content, stream: stream, index: index }
      return self
    end

    if key.respond_to? :each_pair
      key.each_pair { |name, content| metadata name, content, stream: stream, index: index }
      return self
    end

    add_operation metadata_option(stream, index), "#{key}=#{value}"
  end

  def metadata_from input
    add_operation '-map_metadata', input
  end

  def metadata_map input
    metadata_from input
  end

  def metadata_mark value = METADATA_MARK
    metadata :downloaded_with, value
  end

  def metadata_tags entries
    entries.each_pair { |key, value| metadata key, value.to_s.strip }
    self
  end

  def metadata_policy tags: {}, mark: true, source: 0
    metadata_from source
    set_operation [:id3v2], '-id3v2_version', 3
    add_operation '-movflags', 'use_metadata_tags'
    set_operation [:id3v1], '-write_id3v1', 1
    metadata_mark if mark
    metadata_tags tags
  end

  def id3 version: 3, write_v1: true
    set_operation [:id3v2], '-id3v2_version', version
    set_operation [:id3v1], '-write_id3v1', 1 if write_v1
    self
  end

  def format name
    set_operation [:format], '-f', name
  end

  def movflags value
    set_operation [:movflags], '-movflags', value
  end

  def cuda decode: false, encode: false
    @cuda_decode = decode
    @cuda_encode = encode
    self
  end

  def quality value, mode: :auto
    set_semantic_operation [:quality], kind: :quality, value: value, mode: mode.to_sym
  end

  def preset value
    set_operation [:preset], '-preset', value
  end

  def tune value
    set_operation [:tune], '-tune', value
  end

  def multipass value
    set_operation [:multipass], '-multipass', value
  end

  def adaptive_quantization spatial: true, temporal: true
    set_operation [:spatial_aq], '-spatial-aq', boolean_value(spatial)
    set_operation [:temporal_aq], '-temporal-aq', boolean_value(temporal)
    self
  end

  def lookahead value
    set_operation [:lookahead], '-rc-lookahead', value
  end

  def scale width:, modulus: 2
    add_filter FFmpeg.scale_filter(width: width, modulus: modulus), stream: :video
  end

  def maxrate value, stream: nil
    set_operation [:maxrate, stream_name(stream)], option_name('maxrate', stream), value
  end

  def buffer_size value, stream: nil
    set_operation [:buffer_size, stream_name(stream)], option_name('bufsize', stream), value
  end

  def rate_control value, stream: nil
    set_operation [:rate_control, stream_name(stream)], option_name('rc', stream), value
  end

  def overwrite
    set_global [:overwrite], '-y'
  end

  def threads value
    set_global [:threads], '-threads', value.to_i
  end

  def loglevel value
    set_global [:loglevel], '-loglevel', value
  end

  def hide_banner
    set_global [:hide_banner], '-hide_banner'
  end

  def no_stats
    set_global [:no_stats], '-nostats'
  end

  def output destination
    raise ArgumentError, 'output already set' if @output_set

    @output     = destination
    @output_set = true
    self
  end

  def capture
    raise ArgumentError, 'output is required' unless @output_set

    @runner.call command
  ensure
    reset!
  end

  def run! label: 'ffmpeg failed'
    raise ArgumentError, 'output is required' unless @output_set

    destination = @output
    stdout, stderr, status = @runner.call command
    file = destination unless destination == :stdout
    Sh.assert_success! label, stderr, status: status, output: file
    destination == :stdout ? stdout : destination
  ensure
    reset!
  end

  private

  def reset!
    @global_options = []
    @inputs         = []
    @operations     = []
    @filters        = Hash.new { |filters, stream| filters[stream] = [] }
    @cuda_decode    = false
    @cuda_encode    = false
    @output         = nil
    @output_set     = false
    apply_profile
  end

  def apply_profile
    profile = PROFILES.fetch @profile
    profile.each do |option|
      case option
      when :overwrite   then overwrite
      when :threads     then threads @default_threads
      when :loglevel    then loglevel :error
      when :hide_banner then hide_banner
      when :no_stats    then no_stats
      end
    end
  end

  def command
    [
      @ffmpeg,
      *@global_options.flat_map { |option| option[:arguments] },
      *(['-hwaccel', 'cuda'] if @cuda_decode),
      *@inputs.flatten,
      *@operations.flat_map { |operation| operation_arguments operation },
      output_argument
    ].compact
  end

  def output_argument
    @output == :stdout ? '-' : @output.to_s
  end

  def add_filter_operation stream
    return if @operations.any? { |operation| operation[:key] == [:filter, stream] }

    @operations << {key: [:filter, stream], kind: :filter, stream: stream}
  end

  def add_operation flag, value = nil
    arguments = [flag]
    arguments << value.to_s unless value.nil?
    @operations << {arguments: arguments}
    self
  end

  def set_operation key, flag, value = nil
    arguments = [flag]
    arguments << value.to_s unless value.nil?
    set_semantic_operation key, arguments: arguments
  end

  def set_global key, flag, value = nil
    arguments = [flag]
    arguments << value.to_s unless value.nil?
    option = @global_options.find { |entry| entry[:key] == key }
    if option
      option[:arguments] = arguments
    else
      @global_options << {key: key, arguments: arguments}
    end
    self
  end

  def set_semantic_operation key, attributes
    operation = @operations.find { |entry| entry[:key] == key }
    if operation
      operation.replace key: key, **attributes
    else
      @operations << {key: key, **attributes}
    end
    self
  end

  def operation_arguments operation
    case operation[:kind]
    when :filter
      filters = @filters.fetch operation[:stream]
      ["-#{operation[:stream]}f", filters.join(',')]
    when :quality
      mode = operation[:mode] == :auto ? (@cuda_encode ? :cq : :crf) : operation[:mode]
      ["-#{mode}", operation[:value].to_s]
    else
      operation[:arguments]
    end
  end

  def stream_name stream
    return nil if stream.nil?

    STREAMS.fetch stream.to_sym, stream.to_s.sub(/\A:/, '')
  end

  def option_name name, stream
    suffix = stream_name stream
    suffix ? "-#{name}:#{suffix}" : "-#{name}"
  end

  def metadata_option stream, index
    return option_name('metadata', stream) if index.nil?
    raise ArgumentError, 'metadata index requires a stream' if stream.nil?

    "-metadata:#{stream_name stream}:#{index}"
  end

  def boolean_value value
    value ? '1' : '0'
  end

  def rate_value value, unit
    suffix = {bit: '', kbit: 'k', mbit: 'M'}.fetch unit.to_sym
    "#{value}#{suffix}"
  end

  def fresh profile: @profile
    self.class.new(
      ffmpeg:  @ffmpeg,
      ffprobe: @ffprobe,
      runner:  @runner,
      threads: @default_threads,
      profile: profile,
      fdk_aac: @fdk_aac
    )
  end

  def one_shot
    reset!
    yield
  ensure
    reset!
  end

  def run_one_shot profile: @profile, label:
    one_shot do
      builder = fresh profile: profile
      yield builder
      builder.run! label: label
    end
  end

  def run_probe arguments, label:
    stdout, stderr, status = @runner.call [@ffprobe, *arguments]
    Sh.assert_success! label, stderr, status: status
    stdout
  end

  def audio_analysis kind, silence_threshold_db
    {
      signal: [
        'astats=metadata=0:reset=0',
        'audio signal analysis failed'
      ],
      frame_signal: [
        'astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-',
        'audio frame signal analysis failed'
      ],
      loudness: [
        'ebur128=peak=true',
        'audio loudness analysis failed'
      ],
      silence: [
        "silencedetect=noise=#{silence_threshold_db}dB:d=0.08",
        'audio silence analysis failed'
      ]
    }.fetch kind
  end
end
