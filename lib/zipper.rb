require 'tempfile'
require 'securerandom'
require 'fileutils'
require 'digest'
require 'json'
require_relative 'prober'
require_relative 'utils/safety'
require_relative 'utils/time_ranges'
require_relative 'subtitler/ass'
require_relative 'zipper/formats'
require_relative 'zipper/limits'
require_relative 'zipper/subtitle'

class Zipper

  class_attribute :size_mb_limit
  class_attribute :pause_cache
  class_attribute :pause_cache_mutex

  # Constants removed; quality defaults are set dynamically per instance.
  VFR_OPTS    = '-fps_mode vfr'
  VF_SCALE_M2 = "scale=%{width}:trunc(ow/a/2)*2".freeze
  VF_SCALE_M8 = "scale=%{width}:trunc(ow/a/8)*8".freeze

  META_MARK  = '-metadata downloaded_with=t.me/media_downloader_2bot'.freeze
  META_OPTS  = '-map_metadata 0 -id3v2_version 3 -movflags use_metadata_tags -write_id3v1 1 %{metadata}'.freeze

  AUDIO_POST_OPTS  = ''
  AUDIO_POST_OPTS << " #{META_OPTS}" unless ENV['SKIP_META']
  VIDEO_POST_OPTS  = '-movflags +faststart'
  VIDEO_POST_OPTS << " #{META_OPTS}" unless ENV['SKIP_META']
  VIDEO_POST_OPTS.freeze

  AUDIO_ENC = Zipper::Formats::AUDIO_ENC

  VOICE_QUALITY_FILTER = (
    'highpass=f=80,lowpass=f=9000,afftdn=nf=-25,' \
    'acompressor=threshold=-18dB:ratio=2.5:attack=20:release=250,' \
    'dynaudnorm=f=150:g=15,loudnorm=I=-16:TP=-1.5:LRA=11,volume=-2.5dB'
  ).freeze
  SPEECH_CLEANUP_FILTER = 'highpass=f=80'.freeze

  THREADS = ENV['THREADS']&.to_i || 16
  FFMPEG  = "ffmpeg -y -threads #{THREADS} -loglevel error"

  # General templates with placeholder keys. Substitutions can be blank strings.
  VIDEO_CMD_TPL = (
    "#{FFMPEG} %{pre_iopts} -i %{infile} %{iopts} -filter_complex \"%{fgraph}\" " \
    "#{VFR_OPTS} %{maps} %{vflags} %{acodec} %{vpost} %{oopts} %{outfile}"
  ).freeze

  AUDIO_CMD_TPL = (
    "#{FFMPEG} -vn -i %{infile} %{iopts} %{acodec} %{apost} %{oopts} %{outfile}"
  ).freeze

  FG_SEP      = ','.freeze
  INPUT_LINE  = "-i %{infile} %{iopts} -filter_complex \"#{VF_SCALE_M2}#{FG_SEP}%{fgraph}\" #{VFR_OPTS} %{maps}"
  INPUT8_LINE = "-i %{infile} %{iopts} -filter_complex \"#{VF_SCALE_M8}#{FG_SEP}%{fgraph}\" #{VFR_OPTS} %{maps}"

  # Delegated codec definitions
  Types = Zipper::Formats::TYPES

  def self.max_audio_duration br
    Limits.max_audio_duration(br, size_mb_limit)
  end

  # Dynamic helpers that reevaluate the thresholds at runtime
  def self.vid_duration_thld
    Limits.vid_duration_thld(size_mb_limit)
  end

  def self.aud_duration_thld
    Limits.aud_duration_thld(size_mb_limit)
  end

  def self.zip_video *args, **params
    self.new(*args, **params).zip_video
  end
  def self.zip_audio *args, **params
    self.new(*args, **params).zip_audio
  end

  def self.concat_audio inputs, outfile, stl: nil
    return FileUtils.cp inputs.first, outfile if inputs.size == 1

    signatures = inputs.map { |input| Prober.audio_signature(input) }
    Dir.mktmpdir do |dir|
      listfile = File.join(dir, 'concat.txt')
      File.write listfile, inputs.map { |p| Utils::Safety.concat_manifest_path(p) }.join("\n")

      cmd = if concat_copy_safe?(signatures)
        "#{FFMPEG} -f concat -safe 0 -i #{Sh.escape(listfile)} -c copy #{Sh.escape(outfile)}"
      else
        concat_filter_cmd(inputs, outfile, signatures)
      end

      _, _, status = Sh.run cmd
      raise 'FFmpeg concat failed' unless status.success?
    end

    outfile
  end

  self.pause_cache       = {}
  self.pause_cache_mutex = Mutex.new

  def self.silence_file(path, seconds, sample_rate: 22_050, format: nil, amplitude: nil)
    format = normalize_audio_format(format)
    sample_rate = format[:sample_rate].to_i if format[:sample_rate].to_i.positive?
    channels = format[:channels].to_i
    layout   = format[:channel_layout].to_s
    layout   = channel_layout_for(channels) if layout.empty?
    source = if amplitude.to_f.positive?
      "anoisesrc=color=white:amplitude=#{amplitude.to_f}:sample_rate=#{sample_rate.to_i}"
    else
      "anullsrc=channel_layout=#{Sh.escape(layout)}:sample_rate=#{sample_rate.to_i}"
    end
    filter = amplitude.to_f.positive? ? ' -af lowpass=f=6000' : ''
    output = pause_output_options(format, sample_rate: sample_rate, channels: channels, layout: layout)
    cmd = "#{FFMPEG} -f lavfi -i #{source}#{filter} -t #{seconds} #{output}#{Sh.escape(path)}"
    _, err, status = Sh.run cmd
    Sh.assert_success!('Failed to create silent audio file', err, status: status, output: path)
    path
  end

  def self.get_pause_file seconds, dir, sample_rate: nil, extension: '.wav', format: nil, amplitude: nil
    return nil if seconds.to_f <= 0
    key = seconds.to_f.round(3)
    sample_rate = (sample_rate || 22_050).to_i

    extension = ".#{extension}" unless extension.start_with?('.')
    raise ArgumentError, "invalid audio extension: #{extension}" unless extension.match?(/\A\.[a-z0-9]+\z/i)

    format = normalize_audio_format(format)
    sample_rate = format[:sample_rate].to_i if format[:sample_rate].to_i.positive?
    format[:sample_rate] = sample_rate unless format.empty?
    format_key = pause_format_key(format)
    format_suffix = format_key ? "_#{format_key}" : ''
    amplitude_key = amplitude.to_f.positive? ? "_#{amplitude.to_f.to_s.tr('.', '_')}" : ''
    cache_key = "#{dir}:#{key}:#{sample_rate}:#{extension}:#{format_suffix}:#{amplitude_key}"
    pause_file = File.join(dir, "pause_#{key.to_s.gsub('.', '_')}_#{sample_rate}#{format_suffix}#{amplitude_key}#{extension}")
    cached_pause_file(cache_key, pause_file) do
      silence_file(pause_file, key, sample_rate: sample_rate, format: format, amplitude: amplitude)
    end
  end

  def self.normalize_audio_format(format)
    format ? format.to_h.transform_keys(&:to_sym) : {}
  end

  def self.pause_format_key(format)
    return if format.empty?

    serialized = format.sort_by { |key, _value| key.to_s }.to_h
    Digest::SHA256.hexdigest(JSON.generate(serialized))[0, 12]
  end

  def self.pause_output_options(format, sample_rate:, channels:, layout:)
    return '' if format.empty?

    codec = format[:codec_name].to_s
    options = ["-ar #{sample_rate.to_i}"]
    options << "-ac #{channels}" if channels.positive?
    options << "-channel_layout #{Sh.escape(layout)}" unless layout.empty?

    encoder = pause_encoder(format)
    options << "-c:a #{encoder}" if encoder

    profile = pause_profile(format, encoder)
    options << "-profile:a #{profile}" if profile

    bit_rate = format[:bit_rate].to_i
    if encoder && bit_rate.positive? && !codec.start_with?('pcm_') && codec != 'flac'
      options << "-b:a #{bit_rate}"
    end

    sample_fmt = format[:sample_fmt].to_s
    options << "-sample_fmt #{Sh.escape(sample_fmt)}" if codec.start_with?('pcm_') && !sample_fmt.empty?
    "#{options.join(' ')} "
  end

  def self.pause_encoder(format)
    codec = format[:codec_name].to_s
    return if codec.empty?

    if codec == 'aac'
      profile = format[:profile].to_s
      return unless Formats::FDK_AAC || !profile.match?(/HE-AAC/i)

      return Formats::FDK_AAC ? 'libfdk_aac' : 'aac'
    end

    mapped = {
      'mp3'    => 'libmp3lame',
      'opus'   => 'libopus',
      'vorbis' => 'libvorbis',
    }
    return mapped[codec] if mapped.key?(codec)
    return codec if codec.start_with?('pcm_') || codec.in?(%w[ac3 alac eac3 flac])
  end

  def self.pause_profile(format, encoder)
    return unless format[:codec_name].to_s == 'aac' && encoder

    {
      'LC'        => 'aac_low',
      'HE-AAC'    => 'aac_he',
      'HE-AACV2'  => 'aac_he_v2',
    }[format[:profile].to_s.upcase]
  end

  def self.channel_layout_for(channels)
    {1 => 'mono', 2 => 'stereo'}[channels.to_i] || 'mono'
  end

  def self.cached_pause_file cache_key, path
    pause_cache_mutex.synchronize do
      pause_cache[cache_key] ||= begin
        yield unless File.exist?(path)
        path
      end
    end
  end

  def self.add_audio_floor! wav_path, amplitude:, loudness_lufs:, sample_rate: 22_050
    output = File.join(File.dirname(wav_path), "audio_floor_#{SecureRandom.hex(4)}.wav")
    source = "anoisesrc=color=white:amplitude=#{amplitude}:sample_rate=#{sample_rate}"
    filter = "[0:a]loudnorm=I=#{loudness_lufs}:TP=-2:LRA=11[speech];[1:a]lowpass=f=6000[floor];" \
      '[speech][floor]amix=inputs=2:duration=first:dropout_transition=0:normalize=0,' \
      'alimiter=limit=0.841395:attack=5:release=50:level=false'
    command = "#{FFMPEG} -i #{Sh.escape(wav_path)} -f lavfi -i #{Sh.escape(source)} " \
              "-filter_complex #{Sh.escape(filter)} -ac 1 -ar #{sample_rate} " \
              "-c:a pcm_s16le #{Sh.escape(output)}"
    _, stderr, status = Sh.run(command)
    Sh.assert_success!('Failed to add audiobook audio floor', stderr, status: status, output: output)
    FileUtils.mv output, wav_path, force: true
    wav_path
  end

  def self.prepend_silence! wav_path, seconds, dir: nil
    return wav_path if seconds.to_f <= 0
    dir ||= File.dirname(wav_path)

    pause_file = get_pause_file(seconds, dir)
    return wav_path unless pause_file

    out = File.join(dir, "out_#{SecureRandom.hex(4)}.wav")
    concat_audio([pause_file, wav_path], out)
    FileUtils.mv out, wav_path, force: true
    wav_path
  end

  def self.speed_audio_file! wav_path, speed
    speed = speed.to_f
    return wav_path unless speed.positive? && speed != 1

    dir = File.dirname(wav_path)
    out = File.join(dir, "speed_#{SecureRandom.hex(4)}.wav")
    cmd = "#{FFMPEG} -i #{Sh.escape(wav_path)} -af #{Sh.escape(speech_speed_filter(speed))} -c:a pcm_s16le #{Sh.escape(out)}"
    _, err, status = Sh.run cmd
    Sh.assert_success!('Failed to apply audio speed', err, status: status, output: out)
    FileUtils.mv out, wav_path, force: true
    wav_path
  end

  def self.speech_speed_filter(speed)
    "rubberband=tempo=#{speed}:pitch=1:transients=smooth:detector=soft:phase=laminar:window=long:formant=preserved"
  end

  def self.choose_format(*args)
    Zipper::Formats.choose_format(*args)
  end

  def self.extract_vtt infile, language
    self.new(infile, nil, opts: SymMash.new(format: {})).extract_vtt language
  end

  attr_reader :infile, :outfile, :probe, :stl
  attr_reader :info
  attr_reader :iopts, :oopts, :dopts, :opts
  attr_reader :fgraph, :maps
  attr_reader :duration, :cuts, :silences
  attr_reader :type

  def initialize infile, outfile, info: nil, probe: nil, stl: nil, opts: SymMash.new
    @infile  = infile
    @outfile = outfile
    @info    = info
    @probe   = probe ||= Prober.for infile
    @stl     = stl

    @iopts = ''; @oopts = ''; @dopts = opts.format.opts.dup
    @opts = opts
    @dopts.width = Formats.default_width(Zipper.size_mb_limit) if @dopts.width
    if Formats.cuda_encode?(opts) && opts.format.in?([Types.video.h264, Types.video.h265])
      @dopts.quality = 33
    end
    @opts.reverse_merge! dopts

    @fgraph                 = []
    @audio_filters          = []
    @audio_reencode_required = false
    @fgraph << Utils::Safety.safe_filter(opts.vf) if opts.vf.present?

    @maps = []

    @cuts     = Utils::TimeRanges.parse(opts.cuts, option: :cuts)
    @silences = Utils::TimeRanges.parse(opts.silences, option: :silences)
    source_duration = probe.format.duration.to_f
    cuts.validate!(source_duration, allow_entire: false)
    silences.validate!(source_duration)

    opts.speed   = opts.speed&.to_f || 1
    opts.width   = opts.width&.to_i
    opts.quality = opts.quality&.to_i if opts.quality
    opts.abrate  = opts.abrate&.to_i
    # Use the instance variable to avoid referencing the (possibly nil) local parameter.
    @duration    = (source_duration - cuts.total_duration) / opts.speed
    opts.cudaenc = Formats.cuda_encode?(opts)
    opts.cudadec = Formats.cuda_decode?(opts)
    opts.cuda    = opts.cudaenc || opts.cudadec
  end

  # Detect the current format key (e.g. :h264, :aac).
  def format_name
    @format_name ||= begin
      v = opts.format
      case v
      when Types.video.h264 then :h264
      when Types.video.h265 then :h265
      when Types.video.av1  then :av1
      when Types.video.vp9  then :vp9
      when Types.audio.opus then :opus
      when Types.audio.aac  then :aac
      when Types.audio.mp3  then :mp3
      else :unknown end
    end
  end

  def video?; @type == :video; end
  def audio?; @type == :audio; end

  def zip_video
    @type = :video

    # Ensure the NVENC encoder receives frames in a supported pixel format
    # add it early so it comes right after the scale* filter and before any
    # other dynamically-added filters, avoiding a dangling comma when no
    # other filters are present.
    fgraph << 'format=yuv420p' if opts.cudaenc && !fgraph.include?('format=yuv420p')
    check_width
    reduce_framerate
    limit_framerate
    apply_audio_rate
    apply_audio_channels

    Zipper::Subtitle.apply(self)
    apply_media_edits
    apply_speed
    apply_cut
    append_audio_filter_options
    size_opts = apply_video_size_limits

    acodec = video_audio_codec

    full_fgraph  = (scale_filters + fgraph).join(FG_SEP)
    maps_str     = maps.map { |m| "-map #{m}" }.join(' ')

    # Video encoder specific flags defined by format spec.
    spec         = opts.format
    preset       = if opts.cudaenc
      spec.preset_cuda || 'medium'
    else
      spec.preset_cpu || 'fast'
    end

    vcodec       = opts.cudaenc ? (spec.codec_cuda || spec.codec_cpu) : spec.codec_cpu
    qflag        = opts.cudaenc ? (spec.qflag_cuda || spec.qflag_cpu) : spec.qflag_cpu
    extra        = opts.cudaenc ? (spec.extra_cuda || '')            : (spec.extra_cpu || '')

    v_flags_parts = ["-c:v #{vcodec}"]
    v_flags_parts << "#{qflag} #{opts.quality}" if qflag.present? && opts.quality
    v_flags_parts << "-preset #{preset}"
    v_flags_parts << extra if extra.present?
    v_flags_parts << size_opts if size_opts.present?

    v_flags = v_flags_parts.join(' ')

    video_post_opts = VIDEO_POST_OPTS % {metadata: metadata_args}

    cmd_params = {
      pre_iopts: video_input_opts,
      infile:    Sh.escape(infile),
      iopts:     iopts,
      fgraph:    full_fgraph,
      maps:      maps_str,
      vflags:    v_flags,
      acodec:    acodec,
      vpost:     video_post_opts,
      oopts:     oopts,
      outfile:   Sh.escape(outfile),
    }

    cmd = VIDEO_CMD_TPL % cmd_params
    cmd.squeeze!(" ")
    Sh.run cmd
  end

  def video_input_opts
    [
      (opts.cudadec ? '-hwaccel cuda' : nil),
      (opts.keyframes ? '-skip_frame nokey' : nil),
    ].compact.join(' ')
  end

  def video_audio_codec
    return '-an' if opts.noaudio || opts.no_audio
    return '-c:a copy' if opts.dub && !audio_reencode_required?

    aenc = AUDIO_ENC[opts.acodec&.to_sym] || AUDIO_ENC.opus
    opts.abrate ||= opts.format&.opts&.abrate || 64
    opts.abrate = (aenc.percent * opts.abrate).round if size_mb_limit
    aenc.encode % {abrate: opts.abrate}
  end

  def scale_filters
    stream = probe.streams.find { |s| s.codec_type == 'video' }
    return preserve_resolution_scale(stream) if opts.preserve_resolution

    scale_expr = (format_name == :vp9 ? VF_SCALE_M8 : VF_SCALE_M2) % {width: opts.width}
    [scale_expr]
  end

  def preserve_resolution_scale(stream)
    mod = format_name == :vp9 ? 8 : 2
    return [] if stream.width % mod == 0 && stream.height % mod == 0

    ["scale=trunc(iw/#{mod})*#{mod}:trunc(ih/#{mod})*#{mod}"]
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
    append_audio_filter_options

    # Encoder template defined by format spec
    acodec_tmpl = opts.format.encode
    acodec      = acodec_tmpl % {abrate: opts.bitrate}

    audio_post_opts = AUDIO_POST_OPTS % {metadata: metadata_args}
    # Do not force channels; let encoder decide (previously caused artifacts)

    cmd_params = {
      infile:  Sh.escape(infile),
      iopts:   iopts,
      acodec:  acodec,
      apost:   audio_post_opts,
      oopts:   oopts,
      outfile: Sh.escape(outfile),
    }

    cmd = AUDIO_CMD_TPL % cmd_params
    cmd.squeeze!(" ")
    Sh.run cmd
  end

  def subtitle_to_vtt body, ext
    Subtitler::VTT.to_vtt(body, ext)
  end

  def extract_vtt lang_or_index
    vttfile = "#{File.basename infile, File.extname(infile)}.vtt"

    subs  = probe.streams.select{ |s| s.codec_type == 'subtitle' }
    index = if lang_or_index.is_a? Numeric then lang_or_index else subs.index{ |s| s.tags.language == lang_or_index } end

    vtt, _, _ = Sh.run "#{FFMPEG} -i #{Sh.escape infile} -map 0:s:#{index} -c:s webvtt -f webvtt -"
    Zipper::Subtitle.sanitize_vtt vtt
  end

  def self.audio_to_wav(path, sample_rate: nil, channels: nil)
    wpath = File.join(Dir.pwd, "audio-#{SecureRandom.hex(6)}.wav")
    format = [("-ac #{channels.to_i}" if channels), ("-ar #{sample_rate.to_i}" if sample_rate)].compact.join(' ')

    cmd = "#{FFMPEG} -i #{Sh.escape(path)} #{format} #{Sh.escape(wpath)}"
    _, _, st = Sh.run cmd
    raise 'ffmpeg failed' unless st.success?

    wpath
  end

  def self.with_audio_wav(path, sample_rate: nil, channels: nil)
    options = {sample_rate: sample_rate, channels: channels}.compact
    wav = audio_to_wav(path, **options)
    File.open(wav) { |file| yield file }
  ensure
    File.unlink(wav) if wav && File.exist?(wav)
  end

  # Public helper: prepare subtitles and return [vtt, lang, verbose_json]
  def self.prepare_subtitle(*args, **kwargs)
    Zipper::Subtitle.prepare_subtitle(*args, **kwargs)
  end

  # Prepare subtitles (download, transcribe, translate) and return
  # [vtt_string, language_iso, verbose_json_or_nil]
  def prepare_subtitle
    Zipper::Subtitle.prepare(self, translate_to: opts.slang)
  end

  protected

  def self.concat_copy_safe?(signatures)
    signatures.none?(&:empty?) && signatures.uniq.one?
  end

  def self.concat_filter_cmd(inputs, outfile, signatures)
    input_args = inputs.map { |input| "-i #{Sh.escape(input)}" }.join(' ')
    labels = inputs.each_index.map { |idx| "[#{idx}:a]" }.join
    sample_rate = signatures.map { |signature| signature[:sample_rate].to_i }.max
    filter = "#{labels}concat=n=#{inputs.size}:v=0:a=1"
    filter << ",aresample=#{sample_rate}" if sample_rate.positive?
    filter << '[a]'
    "#{FFMPEG} #{input_args} -filter_complex \"#{filter}\" -map \"[a]\" #{Sh.escape(outfile)}"
  end

  attr_reader :audio_filters

  def append_audio_filter(filter)
    audio_filters << filter
    require_audio_reencode
  end

  def append_audio_filter_options
    oopts << " -af #{audio_filters.join(',')}" if audio_filters.present?
  end

  def audio_reencode_required?
    @audio_reencode_required
  end

  def require_audio_reencode
    @audio_reencode_required = true
  end

  def reduce_framerate
    fgraph << mpdecimate_filter if opts.mpdecimate
    return unless opts.nompdecimate
    fgraph << 'mpdecimate'
  end

  def mpdecimate_filter
    opts.mpdecimate == 1 ? 'mpdecimate' : "mpdecimate=#{Utils::Safety.safe_filter(opts.mpdecimate)}"
  end

  def limit_framerate
    # FIXME: conflict with MP4 vsync vfr
    iopts << " -r #{opts.maxfr.to_i}" if opts.maxfr
  end

  def apply_audio_rate
    return unless rate = opts.freq&.to_i || opts.ar&.to_i
    iopts << " -ar #{rate}"
    require_audio_reencode
  end

  def apply_audio_channels
    # Workaround for "Channel layout change is not supported"
    # https://www.atlas-informatik.ch/multimediaXpert/Convert.en.html
    return unless opts.ac

    iopts << " -ac #{opts.ac.to_i}"
    require_audio_reencode
  end

  def apply_audio_size_limit
    Zipper::Limits.apply_audio_size_limit!(self)
  end

  def apply_video_size_limits
    Zipper::Limits.apply_video_size_limits!(self)
  end

  def apply_speed
    return if opts.speed == 1

    fgraph << "setpts=PTS/#{opts.speed}" if video?
    #iopts  << " -t #{duration}" # attached subtitle mess with the length of the video
    append_audio_filter "atempo=#{opts.speed}"
  end

  def apply_media_edits
    apply_silences
    apply_cuts
  end

  def apply_silences
    return if silences.empty? || !audio_stream?

    append_audio_filter "volume=0:enable='#{interval_expression(silences)}'"
  end

  def apply_cuts
    return if cuts.empty?

    expression = "not(#{interval_expression(cuts)})"
    if video?
      fgraph << "select='#{expression}'"
      fgraph << 'setpts=N/FRAME_RATE/TB'
    end
    return unless audio_stream?

    append_audio_filter "aselect='#{expression}'"
    append_audio_filter 'asetpts=N/SR/TB'
  end

  def interval_expression(ranges)
    ranges.intervals.map do |interval|
      "between(t\\,#{time_value(interval.start)}\\,#{time_value(interval.finish)})"
    end.join('+')
  end

  def time_value(value)
    return value.to_i.to_s if value.to_i == value

    format('%.3f', value).sub(/0+\z/, '').delete_suffix('.')
  end

  def audio_stream?
    probe.streams.any? { |stream| stream.codec_type == 'audio' }
  end

  def apply_voice_quality
    append_audio_filter VOICE_QUALITY_FILTER if opts.voice_quality
  end

  def apply_speech_cleanup
    append_audio_filter SPEECH_CLEANUP_FILTER if opts.speech_cleanup
  end

  def check_width
    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
    # Ensure a sane default width
    opts.width ||= opts.format&.opts&.width || vstrea&.width || 720
    if opts.preserve_resolution
      opts.width = vstrea.width
      return
    end

    if opts.vf&.index 'transpose'
    elsif vstrea.width < vstrea.height # portrait image
      opts.width /= 2
    end

    # lower resolution
    opts.width = vstrea.width if vstrea.width < opts.width
  end

  # Generate an SRT file from the given media and return its path
  def self.generate_srt(*args, **kwargs)
    Zipper::Subtitle.generate_srt(*args, **kwargs)
  end

  def metadata_args
    parts = []
    parts << META_MARK unless ENV['SKIP_METAMARK'] || opts.skip_metamark
    parts.concat((opts.metadata || {}).map { |k, v| "-metadata #{Sh.escape k}=#{Sh.escape v.to_s.strip}" })
    parts.join(' ')
  end

  def apply_cut
    iopts << " -ss #{opts.ss}" if Utils::Safety.safe_time?(opts.ss)
    oopts << " -to #{opts.to}" if Utils::Safety.safe_time?(opts.to)
  end

end
