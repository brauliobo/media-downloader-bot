require 'tempfile'
require 'securerandom'
require 'fileutils'
require 'digest'
require 'json'

require_relative 'ffmpeg'
require_relative 'prober'
require_relative 'utils/safety'
require_relative 'utils/duration'
require_relative 'utils/time_ranges'
require_relative 'subtitler/ass'
require_relative 'zipper/formats'
require_relative 'zipper/limits'
require_relative 'zipper/subtitle'
require_relative 'voice_reference/audio_analyzer'

class Zipper
  class_attribute :size_mb_limit
  class_attribute :pause_cache
  class_attribute :pause_cache_mutex

  Types = Zipper::Formats::TYPES
  AUDIO_ENC = Zipper::Formats::AUDIO_ENC

  def self.max_audio_duration br
    Limits.max_audio_duration br, size_mb_limit
  end

  def self.vid_duration_thld
    Limits.vid_duration_thld size_mb_limit
  end

  def self.aud_duration_thld
    Limits.aud_duration_thld size_mb_limit
  end

  def self.default_ffmpeg
    FFmpeg.new fdk_aac: FFmpeg.fdk_aac_available?
  end

  def self.zip_video *args, **params
    new(*args, **params).zip_video
  end

  def self.zip_audio *args, **params
    new(*args, **params).zip_audio
  end

  def self.concat_audio inputs, outfile, stl: nil, ffmpeg: nil, ffmpeg_factory: nil
    return FileUtils.cp inputs.first, outfile if inputs.size == 1

    builder = ffmpeg || ffmpeg_factory&.call || FFmpeg.new
    signatures = inputs.map { |input| Prober.audio_signature input, ffmpeg: builder }
    Dir.mktmpdir do |dir|
      listfile = File.join dir, 'concat.txt'
      File.write listfile, inputs.map { |path| Utils::Safety.concat_manifest_path path }.join("\n")

      copy = concat_copy_safe? signatures
      sample_rate = signatures.map { |signature| signature[:sample_rate].to_i }.max
      arguments = {
        inputs: copy ? listfile : inputs,
        output: outfile,
        copy:   copy,
        label:  'FFmpeg concat failed',
      }
      arguments[:sample_rate] = sample_rate if !copy && sample_rate.positive?

      begin
        builder.concat_audio(**arguments)
      rescue Sh::Error
        raise 'FFmpeg concat failed'
      end
    end

    outfile
  end

  self.pause_cache       = {}
  self.pause_cache_mutex = Mutex.new

  def self.silence_file path, seconds, sample_rate: 22_050, format: nil, amplitude: nil,
                        ffmpeg: nil, ffmpeg_factory: nil
    format = normalize_audio_format format
    sample_rate = format[:sample_rate].to_i if format[:sample_rate].to_i.positive?
    channels = format[:channels].to_i
    layout = format[:channel_layout].to_s
    layout = channel_layout_for channels if layout.empty?

    builder = ffmpeg || ffmpeg_factory&.call || FFmpeg.new
    encoding = FFmpeg.pause_encoding format
    builder.create_silence(
      output:             path,
      source_sample_rate: sample_rate,
      duration:            seconds,
      filter:              amplitude.to_f.positive? ? FFmpeg.lowpass_filter(6000) : nil,
      sample_rate:         format.empty? ? nil : sample_rate,
      channels:             format.empty? || !channels.positive? ? nil : channels,
      channel_layout:       format.empty? ? nil : layout,
      amplitude:             amplitude,
      codec:                 encoding.codec,
      codec_profile:        encoding.profile,
      bitrate:               encoding.bitrate,
      sample_format:        encoding.sample_format,
      label:                 'Failed to create silent audio file'
    )
    path
  end

  def self.get_pause_file seconds, dir, sample_rate: nil, extension: '.wav', format: nil,
                          amplitude: nil, ffmpeg: nil, ffmpeg_factory: nil
    return nil if seconds.to_f <= 0

    key = seconds.to_f.round 3
    sample_rate = (sample_rate || 22_050).to_i
    extension = ".#{extension}" unless extension.start_with? '.'
    raise ArgumentError, "invalid audio extension: #{extension}" unless extension.match?(/\A\.[a-z0-9]+\z/i)

    format = normalize_audio_format format
    sample_rate = format[:sample_rate].to_i if format[:sample_rate].to_i.positive?
    format[:sample_rate] = sample_rate unless format.empty?
    format_key = pause_format_key format
    format_suffix = format_key ? "_#{format_key}" : ''
    amplitude_key = amplitude.to_f.positive? ? "_#{amplitude.to_f.to_s.tr '.', '_'}" : ''
    cache_key = "#{dir}:#{key}:#{sample_rate}:#{extension}:#{format_suffix}:#{amplitude_key}"
    pause_file = File.join dir, "pause_#{key.to_s.gsub '.', '_'}_#{sample_rate}#{format_suffix}#{amplitude_key}#{extension}"

    cached_pause_file cache_key, pause_file do
      silence_file pause_file, key, sample_rate: sample_rate, format: format, amplitude: amplitude,
                   ffmpeg: ffmpeg, ffmpeg_factory: ffmpeg_factory
    end
  end

  def self.normalize_audio_format format
    format ? format.to_h.transform_keys(&:to_sym) : {}
  end

  def self.pause_format_key format
    return if format.empty?

    serialized = format.sort_by { |key, _value| key.to_s }.to_h
    Digest::SHA256.hexdigest(JSON.generate serialized)[0, 12]
  end

  def self.pause_encoder format, fdk_aac: nil
    FFmpeg.pause_encoding(format, fdk_aac: fdk_aac).codec
  end

  def self.pause_profile format, encoder, fdk_aac: nil
    return unless encoder

    FFmpeg.pause_encoding(format, fdk_aac: fdk_aac).profile
  end

  def self.pause_bitrate format, encoder, fdk_aac: nil
    return unless encoder

    FFmpeg.pause_encoding(format, fdk_aac: fdk_aac).bitrate
  end

  def self.pause_sample_format format, encoder, fdk_aac: nil
    FFmpeg.pause_encoding(format, fdk_aac: fdk_aac).sample_format
  end

  def self.channel_layout_for channels
    {1 => 'mono', 2 => 'stereo'}[channels.to_i] || 'mono'
  end

  def self.cached_pause_file cache_key, path
    pause_cache_mutex.synchronize do
      pause_cache[cache_key] ||= begin
        yield unless File.exist? path
        path
      end
    end
  end

  def self.add_audio_floor! wav_path, amplitude:, loudness_lufs:, sample_rate: 22_050,
                              ffmpeg: nil, ffmpeg_factory: nil
    output = File.join File.dirname(wav_path), "audio_floor_#{SecureRandom.hex 4}.wav"
    builder = ffmpeg || ffmpeg_factory&.call || FFmpeg.new
    builder.add_audio_floor(
      input: wav_path, output: output, amplitude: amplitude, loudness_lufs: loudness_lufs,
      sample_rate: sample_rate, label: 'Failed to add audiobook audio floor'
    )
    FileUtils.mv output, wav_path, force: true
    wav_path
  end

  def self.prepend_silence! wav_path, seconds, dir: nil, ffmpeg: nil, ffmpeg_factory: nil
    return wav_path if seconds.to_f <= 0

    dir ||= File.dirname wav_path
    pause_file = get_pause_file seconds, dir, ffmpeg: ffmpeg, ffmpeg_factory: ffmpeg_factory
    return wav_path unless pause_file

    output = File.join dir, "out_#{SecureRandom.hex 4}.wav"
    concat_audio [pause_file, wav_path], output, ffmpeg: ffmpeg, ffmpeg_factory: ffmpeg_factory
    FileUtils.mv output, wav_path, force: true
    wav_path
  end

  def self.speed_audio_file! wav_path, speed, ffmpeg: nil, ffmpeg_factory: nil
    speed = speed.to_f
    return wav_path unless speed.positive? && speed != 1

    output = File.join File.dirname(wav_path), "speed_#{SecureRandom.hex 4}.wav"
    builder = ffmpeg || ffmpeg_factory&.call || FFmpeg.new
    builder.speed_audio(
      input: wav_path, output: output, filter: speech_speed_filter(speed),
      label: 'Failed to apply audio speed'
    )
    FileUtils.mv output, wav_path, force: true
    wav_path
  end

  def self.speech_speed_filter speed
    FFmpeg.speech_speed_filter speed
  end

  def self.choose_format(*args)
    Zipper::Formats.choose_format(*args)
  end

  def self.extract_vtt infile, language, ffmpeg: nil, ffmpeg_factory: nil
    ffmpeg ||= ffmpeg_factory&.call || FFmpeg.new
    new(infile, nil, opts: SymMash.new(format: Types.audio.opus), ffmpeg: ffmpeg,
        ffmpeg_factory: ffmpeg_factory).extract_vtt language, ffmpeg: ffmpeg
  end

  attr_reader :infile, :outfile, :probe, :stl, :info
  attr_reader :iopts, :oopts, :dopts, :opts, :fgraph, :maps
  attr_reader :duration, :cuts, :silences, :type

  def initialize infile, outfile, info: nil, probe: nil, stl: nil, opts: SymMash.new,
                 ffmpeg: nil, ffmpeg_factory: nil
    @infile = infile
    @outfile = outfile
    @info = info
    @ffmpeg = ffmpeg
    @ffmpeg_factory = ffmpeg_factory
    @probe = probe || Prober.for(infile, ffmpeg: ffmpeg_builder)
    @stl = stl

    format_opts = opts.format&.opts || {}
    @dopts = format_opts.dup
    @opts = opts
    @iopts = ''
    @oopts = ''
    @dopts.width = Formats.default_width Zipper.size_mb_limit if @dopts.width
    if Formats.cuda_encode?(opts) && opts.format.in?([Types.video.h264, Types.video.h265])
      @dopts.quality = 33
    end
    @opts.reverse_merge! @dopts

    @fgraph = []
    @audio_filters = []
    @audio_reencode_required = false
    @fgraph << Utils::Safety.safe_filter(opts.vf) if opts.vf.present?
    @input_seek = nil
    @output_end = nil
    @output_duration = nil
    @output_frame_rate = nil
    @audio_sample_rate = nil
    @audio_channels = nil
    @subtitle_input_path = nil
    @subtitle_language = nil
    @subtitle_burn_filter = nil
    @subtitle_burn_index = nil
    @maps = []

    @cuts = Utils::TimeRanges.parse opts.cuts, option: :cuts
    @silences = Utils::TimeRanges.parse opts.silences, option: :silences
    source_duration = @probe.format.duration.to_f
    cuts.validate! source_duration, allow_entire: false
    silences.validate! source_duration

    opts.speed = opts.speed&.to_f || 1
    opts.width = opts.width&.to_i
    opts.quality = opts.quality&.to_i if opts.quality
    opts.abrate = opts.abrate&.to_i if opts.abrate
    @duration = (source_duration - cuts.total_duration) / opts.speed
    opts.cudaenc = Formats.cuda_encode? opts
    opts.cudadec = Formats.cuda_decode? opts
    opts.cuda = opts.cudaenc || opts.cudadec
  end

  def format_name
    @format_name ||= begin
      case opts.format
      when Types.video.h264 then :h264
      when Types.video.h265 then :h265
      when Types.video.av1 then :av1
      when Types.video.vp9 then :vp9
      when Types.audio.opus then :opus
      when Types.audio.aac then :aac
      when Types.audio.mp3 then :mp3
      else :unknown
      end
    end
  end

  def video?
    @type == :video
  end

  def audio?
    @type == :audio
  end

  def zip_video
    @type = :video
    pixel_format = FFmpeg.format_filter :yuv420p
    fgraph << pixel_format if opts.cudaenc && !fgraph.include?(pixel_format)
    check_width
    reduce_framerate
    limit_framerate
    apply_audio_rate
    apply_audio_channels
    Zipper::Subtitle.apply self
    apply_media_edits
    apply_speed
    apply_cut

    size = apply_video_size_limits
    builder = ffmpeg_builder
    input_options = video_input_opts
    builder.input infile, **input_options
    builder.input subtitle_input_path if subtitle_input_path
    builder.seek input_seek if input_seek
    builder.output_sample_rate audio_sample_rate if audio_sample_rate
    builder.output_channels audio_channels if audio_channels
    builder.output_frame_rate output_frame_rate if output_frame_rate
    add_video_scale builder
    video_filters_before_subtitle.each { |filter| builder.add_filter filter, stream: :video }
    builder.add_filter subtitle_burn_filter, stream: :video if subtitle_burn_filter
    video_filters_after_subtitle.each { |filter| builder.add_filter filter, stream: :video }
    audio_filters.each { |filter| builder.add_filter filter, stream: :audio }
    builder.frame_rate_mode :vfr
    add_maps builder
    builder.metadata :language, subtitle_language, stream: :subtitle if subtitle_input_path && subtitle_language
    builder.metadata :title, subtitle_language, stream: :subtitle if subtitle_input_path && subtitle_language
    builder.subtitle_codec if subtitle_input_path
    builder.encode_video format_name, cuda: opts.cudaenc, quality: opts.quality
    apply_video_size builder, size
    apply_video_audio builder
    apply_metadata builder
    apply_output_bounds builder
    builder.output outfile
    builder.capture
  end

  def zip_audio
    @type = :audio
    apply_audio_rate
    apply_audio_channels
    apply_speech_cleanup
    apply_voice_quality
    apply_media_edits
    apply_speed
    apply_audio_size_limit
    apply_cut

    builder = ffmpeg_builder
    builder.disable :video
    builder.input infile
    builder.seek input_seek if input_seek
    builder.output_sample_rate audio_sample_rate if audio_sample_rate
    builder.output_channels audio_channels if audio_channels
    audio_filters.each { |filter| builder.add_filter filter, stream: :audio }
    builder.encode_audio format_name, bitrate: opts.bitrate
    apply_metadata builder
    apply_output_bounds builder
    builder.output outfile
    builder.capture
  end

  def subtitle_to_vtt body, ext
    Subtitler::VTT.to_vtt body, ext, ffmpeg: ffmpeg_builder
  end

  def video_input_opts
    options = {}
    options[:cuda] = true if opts.cudadec
    options[:keyframes_only] = true if opts.keyframes
    options
  end

  def scale_filters
    stream = probe.streams.find { |candidate| candidate.codec_type == 'video' }
    return preserve_resolution_scale stream if opts.preserve_resolution

    modulus = format_name == :vp9 ? 8 : 2
    [FFmpeg.scale_filter(width: opts.width, modulus: modulus)]
  end

  def preserve_resolution_scale stream
    modulus = format_name == :vp9 ? 8 : 2
    return [] if stream.width % modulus == 0 && stream.height % modulus == 0

    [FFmpeg.preserve_resolution_scale_filter(modulus: modulus)]
  end

  def extract_vtt lang_or_index, ffmpeg: nil
    subtitles = probe.streams.select { |stream| stream.codec_type == 'subtitle' }
    index = if lang_or_index.is_a? Numeric
      lang_or_index
    else
      subtitles.index { |stream| stream.tags.language == lang_or_index }
    end
    ffmpeg ||= @ffmpeg || @ffmpeg_factory&.call || FFmpeg.new
    vtt = ffmpeg.convert_subtitle(
      input: infile, format: :vtt, stream_index: index, label: 'VTT extraction failed'
    )
    Zipper::Subtitle.sanitize_vtt vtt
  end

  def prepare_subtitle
    Zipper::Subtitle.prepare self, translate_to: opts.slang
  end

  def burn_subtitle path
    @subtitle_burn_filter = FFmpeg.subtitle_ass_filter path
    @subtitle_burn_index = fgraph.length
    self
  end

  def add_subtitle_input path, language:
    @subtitle_input_path = path
    @subtitle_language = language
    self
  end

  def self.with_audio_wav path, sample_rate: nil, channels: nil, ffmpeg: nil, ffmpeg_factory: nil
    options = {sample_rate: sample_rate, channels: channels}.compact
    options[:ffmpeg] = ffmpeg if ffmpeg
    options[:ffmpeg_factory] = ffmpeg_factory if ffmpeg_factory
    wav = audio_to_wav path, **options
    File.open(wav) { |file| yield file }
  ensure
    File.unlink wav if wav && File.exist?(wav)
  end

  def self.audio_to_wav path, sample_rate: nil, channels: nil, ffmpeg: nil, ffmpeg_factory: nil
    wav = File.join Dir.pwd, "audio-#{SecureRandom.hex 6}.wav"
    builder = ffmpeg || ffmpeg_factory&.call || FFmpeg.new
    begin
      builder.audio_to_wav(
        input: path, output: wav, sample_rate: sample_rate, channels: channels,
        label: 'ffmpeg failed'
      )
    rescue Sh::Error
      raise 'ffmpeg failed'
    end
    wav
  end

  def self.prepare_subtitle(*args, **kwargs)
    Zipper::Subtitle.prepare_subtitle(*args, **kwargs)
  end

  def self.generate_srt(*args, **kwargs)
    Zipper::Subtitle.generate_srt(*args, **kwargs)
  end

  protected

  attr_reader :audio_filters

  def ffmpeg_builder
    @ffmpeg ||= @ffmpeg_factory&.call || self.class.default_ffmpeg
  end

  def self.concat_copy_safe? signatures
    signatures.none?(&:empty?) && signatures.uniq.one?
  end

  def input_seek
    @input_seek
  end

  def output_end
    @output_end
  end

  def output_duration
    @output_duration
  end

  def output_frame_rate
    @output_frame_rate
  end

  def audio_sample_rate
    @audio_sample_rate
  end

  def audio_channels
    @audio_channels
  end

  def subtitle_input_path
    @subtitle_input_path
  end

  def subtitle_language
    @subtitle_language
  end

  def subtitle_burn_filter
    @subtitle_burn_filter
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
    stream = probe.streams.find { |candidate| candidate.codec_type == 'video' }
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
    builder.map_stream :subtitle, input: 1 if subtitle_input_path
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

  def apply_output_bounds(builder)
    builder.end_at output_end if output_end
    builder.duration output_duration if output_duration
  end

  def apply_audio_size_limit
    Zipper::Limits.apply_audio_size_limit! self
  end

  def apply_video_size_limits
    Zipper::Limits.apply_video_size_limits! self
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

  def interval_expression ranges
    FFmpeg.time_ranges_expression ranges
  end

  def audio_stream?
    probe.streams.any? { |stream| stream.codec_type == 'audio' }
  end

  def apply_voice_quality
    append_audio_filter FFmpeg.voice_quality_filter if opts.voice_quality
  end

  def apply_speech_cleanup
    append_audio_filter FFmpeg.speech_cleanup_filter if opts.speech_cleanup
  end

  def check_width
    stream = probe.streams.find { |candidate| candidate.codec_type == 'video' }
    opts.width ||= opts.format&.opts&.width || stream&.width || 720
    if opts.preserve_resolution
      opts.width = stream.width
      return
    end

    if opts.vf&.index 'transpose'
    elsif stream.width < stream.height
      opts.width /= 2
    end
    opts.width = stream.width if stream.width < opts.width
  end

end
