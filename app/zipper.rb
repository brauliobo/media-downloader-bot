require 'tempfile'
require 'securerandom'
require 'fileutils'
require 'digest'
require 'json'

class Zipper
  include Edits
  include Command

  class_attribute :size_mb_limit

  Types = Zipper::Formats::TYPES
  AUDIO_ENC = Zipper::Formats::AUDIO_ENC

  FORMAT_NAMES = {video: %i[h264 h265 av1 vp9], audio: %i[opus aac mp3]}
    .flat_map { |kind, names| names.map { |name| [Types.public_send(kind)[name], name] } }.to_h

  class << self
    delegate :choose_format, to: Formats
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

  def self.extract_vtt infile, language, ffmpeg: nil, ffmpeg_factory: nil
    ffmpeg = FFmpeg.resolve(ffmpeg, ffmpeg_factory)
    new(infile, nil, opts: SymMash.new(format: Types.audio.opus), ffmpeg: ffmpeg,
        ffmpeg_factory: ffmpeg_factory).extract_vtt language, ffmpeg: ffmpeg
  end

  attr_reader :infile, :outfile, :probe, :stl, :info, :dopts, :opts, :fgraph, :maps, :duration, :cuts, :silences, :type

  def initialize infile, outfile, info: nil, probe: nil, stl: nil, opts: SymMash.new,
                 ffmpeg: nil, ffmpeg_factory: nil
    @infile = infile
    @outfile = outfile
    @info = info
    @ffmpeg = ffmpeg
    @ffmpeg_factory = ffmpeg_factory
    @probe = probe || Prober.for(infile, ffmpeg: ffmpeg_builder)
    @stl = stl
    @opts = opts

    apply_format_defaults!
    reset_graph!
    read_time_ranges!
    normalize_options!
  end

  def format_name
    @format_name ||= FORMAT_NAMES.fetch(opts.format, :unknown)
  end

  def video?
    @type == :video
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
    add_audio_input_options builder
    builder.frame_rate output_frame_rate if output_frame_rate
    add_video_scale builder
    video_filters_before_subtitle.each { |filter| builder.add_filter filter, stream: :video }
    builder.add_filter subtitle_burn_filter, stream: :video if subtitle_burn_filter
    video_filters_after_subtitle.each { |filter| builder.add_filter filter, stream: :video }
    audio_filters.each { |filter| builder.add_filter filter, stream: :audio }
    builder.frame_rate_mode :vfr
    add_maps builder
    add_subtitle_stream builder
    builder.encode_video format_name, cuda: opts.cudaenc, quality: opts.quality
    apply_video_size builder, size
    apply_video_audio builder
    finish_command builder
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
    add_audio_input_options builder
    audio_filters.each { |filter| builder.add_filter filter, stream: :audio }
    builder.encode_audio format_name, bitrate: opts.bitrate
    finish_command builder
  end

  def extract_vtt lang_or_index, ffmpeg: nil
    subtitles = probe.streams.select { |stream| stream.codec_type == 'subtitle' }
    index = if lang_or_index.is_a? Numeric
      lang_or_index
    else
      subtitles.index { |stream| stream.tags.language == lang_or_index }
    end
    ffmpeg ||= FFmpeg.resolve(@ffmpeg, @ffmpeg_factory)
    vtt = ffmpeg.convert_subtitle(
      input: infile, format: :vtt, stream_index: index, label: 'VTT extraction failed'
    )
    Zipper::Subtitle.sanitize_vtt vtt
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

  protected

  attr_reader :audio_filters, :input_seek, :output_end, :output_duration, :output_frame_rate, :audio_sample_rate,
              :audio_channels, :subtitle_input_path, :subtitle_language, :subtitle_burn_filter

  # The format's own options fill in what the request left out.
  def apply_format_defaults!
    @dopts = (@opts.format&.opts || {}).dup
    @dopts.width = Formats.default_width Zipper.size_mb_limit if @dopts.width
    if Formats.cuda_encode?(@opts) && @opts.format.in?([Types.video.h264, Types.video.h265])
      @dopts.quality = 33
    end
    @opts.reverse_merge! @dopts
  end

  def reset_graph!
    @fgraph = []
    @audio_filters = []
    @audio_reencode_required = false
    @fgraph << Utils::Safety.safe_filter(@opts.vf) if @opts.vf.present?
    @input_seek = @output_end = @output_duration = @output_frame_rate = nil
    @audio_sample_rate = @audio_channels = nil
    @subtitle_input_path = @subtitle_language = @subtitle_burn_filter = @subtitle_burn_index = nil
    @maps = []
  end

  def read_time_ranges!
    @cuts = Utils::TimeRanges.parse @opts.cuts, option: :cuts
    @silences = Utils::TimeRanges.parse @opts.silences, option: :silences
    @source_duration = @probe.format.duration.to_f
    cuts.validate! @source_duration, allow_entire: false
    silences.validate! @source_duration
  end

  def normalize_options!
    opts.speed = opts.speed&.to_f || 1
    opts.width = opts.width&.to_i
    opts.quality = opts.quality&.to_i if opts.quality
    opts.abrate = opts.abrate&.to_i if opts.abrate
    @duration = (@source_duration - cuts.total_duration) / opts.speed
    opts.cudaenc = Formats.cuda_encode? opts
    opts.cudadec = Formats.cuda_decode? opts
    opts.cuda = opts.cudaenc || opts.cudadec
  end

  def ffmpeg_builder
    @ffmpeg ||= @ffmpeg_factory&.call || self.class.default_ffmpeg
  end

  def apply_audio_size_limit
    Zipper::Limits.apply_audio_size_limit! self
  end

  def apply_video_size_limits
    Zipper::Limits.apply_video_size_limits! self
  end

  def audio_stream?
    Prober.audio_stream?(probe)
  end

  def check_width
    stream = Prober.video_stream(probe)
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
