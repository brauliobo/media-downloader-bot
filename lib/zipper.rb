require 'tempfile'
require 'securerandom'
require 'fileutils'
require_relative 'exts/sym_mash'
require_relative 'subtitler/ass'
require_relative 'zipper/formats'
require_relative 'zipper/limits'
require_relative 'zipper/subtitle'

class Zipper

  class_attribute :size_mb_limit


  TIME_REGEX   = /(?:\d?\d:)(?:\d?\d:)\d\d/

  # Constants removed; quality defaults are set dynamically per instance.
  VFR_OPTS    = '-vsync vfr'
  VF_SCALE_M2 = "scale=%{width}:trunc(ow/a/2)*2".freeze
  VF_SCALE_M8 = "scale=%{width}:trunc(ow/a/8)*8".freeze

  META_MARK  = '-metadata downloaded_with=t.me/media_downloader_2bot'.freeze
  META_OPTS  = '-map_metadata 0 -id3v2_version 3 -movflags use_metadata_tags -write_id3v1 1'
  META_OPTS << " #{META_MARK} %{metadata}"

  AUDIO_POST_OPTS  = ''
  AUDIO_POST_OPTS << " #{META_OPTS}" unless ENV['SKIP_META']
  VIDEO_POST_OPTS  = '-movflags +faststart'
  VIDEO_POST_OPTS << " #{META_OPTS}" unless ENV['SKIP_META']
  VIDEO_POST_OPTS.freeze

  AUDIO_ENC = Zipper::Formats::AUDIO_ENC

  THREADS = ENV['THREADS']&.to_i || 16
  FFMPEG  = "ffmpeg -y -threads #{THREADS} -loglevel error"

  # General templates with placeholder keys. Substitutions can be blank strings.
  VIDEO_CMD_TPL = (
    "#{FFMPEG} -i %{infile} %{iopts} -filter_complex \"%{fgraph}\" " \
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
    1000 * Zipper.size_mb_limit / (br.to_i / 8) / 60
  end

  # Dynamic helpers that reevaluate the thresholds at runtime
  def self.vid_duration_thld
    return Float::INFINITY unless size_mb_limit
    # Baseline: 20 minutes when the limit is 50 MB (Telegram). Scale linearly with higher limits.
    (size_mb_limit * 20.0 / 50).ceil
  end

  def self.aud_duration_thld
    size_mb_limit ? max_audio_duration(Types.audio.opus.opts.bitrate) : Float::INFINITY
  end

  def self.zip_video *args, **params
    self.new(*args, **params).zip_video
  end
  def self.zip_audio *args, **params
    self.new(*args, **params).zip_audio
  end

  def self.concat_audio inputs, outfile, stl: nil
    return FileUtils.cp inputs.first, outfile if inputs.size == 1

    Dir.mktmpdir do |dir|
      listfile = File.join(dir, 'concat.txt')
      File.write listfile, inputs.map { |p| "file '#{p}'" }.join("\n")

      cmd = [
        'ffmpeg', '-y', '-f', 'concat', '-safe', '0', '-i', Sh.escape(listfile),
        '-c', 'copy', Sh.escape(outfile)
      ].join(' ')

      _, _, status = Sh.run cmd
      raise 'FFmpeg concat failed' unless status.success?
    end

    outfile
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
  attr_reader :duration
  attr_reader :type

  def initialize infile, outfile, info: nil, probe: nil, stl: nil, opts: SymMash.new
    @infile  = infile
    @outfile = outfile
    @info    = info
    @probe   = probe ||= Prober.for infile
    @stl     = stl

    @iopts = ''; @oopts = ''; @dopts = opts.format.opts
    @opts = opts
    @opts.custom_width = true if opts.width
    @opts.reverse_merge! dopts

    @fgraph = []
    @fgraph << opts.vf if opts.vf.present?

    @maps = []

    opts.speed   = opts.speed&.to_f || 1
    opts.width   = opts.width&.to_i
    opts.quality = opts.quality&.to_i if opts.quality
    opts.abrate  = opts.abrate&.to_i
    # Use the instance variable to avoid referencing the (possibly nil) local parameter.
    @duration    = probe.format.duration.to_f / opts.speed
    opts.cuda    = if opts.nocuda then false elsif opts.cuda then true else !!ENV['CUDA'] end

    case opts.format
    when Types.video.h264 then opts.quality = if opts.cuda then 33 else 25 end
    when Types.video.h265 then opts.quality = if opts.cuda then 33 else 25 end
    else opts.quality ||= opts.format.opts.quality
    end
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

  # szopts template depending on codec and CUDA availability.
  def video_sz_template
    spec = opts.format
    if spec.respond_to?(:szopts_cpu) || spec.respond_to?(:szopts_cuda)
      if opts.cuda then spec.szopts_cuda else spec.szopts_cpu end
    else
      spec.szopts || ''
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
    fgraph << 'format=yuv420p' if opts.cuda && !fgraph.include?('format=yuv420p')
    check_width
    reduce_framerate
    limit_framerate
    apply_audio_rate
    apply_audio_channels

    Zipper::Subtitle.apply(self)
    apply_speed
    apply_cut
    szopts = apply_video_size_limits

    aenc        = AUDIO_ENC[opts.acodec&.to_sym] || AUDIO_ENC.opus
    # Ensure abrate is set for video audio track (kbps)
    opts.abrate ||= opts.format&.opts&.abrate || 64
    opts.abrate = (aenc.percent * opts.abrate).round if size_mb_limit
    acodec      = aenc.encode % {abrate: opts.abrate}

    # Build filter graph with scaling first.
    scale_expr   = (format_name == :vp9 ? VF_SCALE_M8 : VF_SCALE_M2) % {width: opts.width}
    full_fgraph  = ([scale_expr] + fgraph).join(FG_SEP)
    maps_str     = maps.map { |m| "-map #{m}" }.join(' ')

    # Video encoder specific flags defined by format spec.
    preset        = opts.cuda ? 'medium' : 'fast'
    spec         = opts.format

    vcodec       = opts.cuda ? (spec.codec_cuda || spec.codec_cpu) : spec.codec_cpu
    qflag        = opts.cuda ? (spec.qflag_cuda || spec.qflag_cpu) : spec.qflag_cpu
    extra        = opts.cuda ? (spec.extra_cuda || '')            : (spec.extra_cpu || '')

    v_flags_parts = ["-c:v #{vcodec}"]
    v_flags_parts << "#{qflag} #{opts.quality}" if qflag.present? && opts.quality
    v_flags_parts << "-preset #{preset}"
    v_flags_parts << extra if extra.present?
    v_flags_parts << szopts if szopts.present?

    v_flags = v_flags_parts.join(' ')

    video_post_opts = VIDEO_POST_OPTS % {metadata: metadata_args}

    cmd_params = {
      infile:  Sh.escape(infile),
      iopts:   iopts,
      fgraph:  full_fgraph,
      maps:    maps_str,
      vflags:  v_flags,
      acodec:  acodec,
      vpost:   video_post_opts,
      oopts:   oopts,
      outfile: Sh.escape(outfile),
    }

    cmd = VIDEO_CMD_TPL % cmd_params
    cmd.squeeze!(" ")
    Sh.run cmd
  end

  def zip_audio
    @type = :audio

    apply_audio_rate
    apply_audio_channels

    apply_speed
    apply_audio_size_limit
    apply_cut

    # Encoder template defined by format spec
    acodec_tmpl = opts.format.encode
    acodec      = acodec_tmpl % {abrate: opts.bitrate}

    audio_post_opts = AUDIO_POST_OPTS % {metadata: metadata_args}

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
    File.write "sub.#{ext}", body
    vtt, _, _ = Sh.run <<-EOC
ffmpeg -i sub.#{ext} -c:s webvtt -f webvtt -
    EOC
    vtt
  end

  def extract_vtt lang_or_index
    vttfile = "#{File.basename infile, File.extname(infile)}.vtt"

    subs  = probe.streams.select{ |s| s.codec_type == 'subtitle' }
    index = if lang_or_index.is_a? Numeric then lang_or_index else subs.index{ |s| s.tags.language == lang_or_index } end

    vtt, _, _ = Sh.run <<-EOC
ffmpeg -loglevel error -i #{Sh.escape infile} -map 0:s:#{index} -c:s webvtt -f webvtt -
    EOC
    vtt
  end

  def self.audio_to_wav path
    wpath = File.join(Dir.tmpdir, "audio-#{SecureRandom.hex(6)}.wav")

    cmd = ['ffmpeg', '-i', Sh.escape(path), '-y', Sh.escape(wpath)].join(' ')
    _, _, st = Sh.run cmd
    raise 'ffmpeg failed' unless st.success?

    wpath
  end

  # Public helper: prepare subtitles and return [vtt, lang, verbose_json]
  def self.prepare_subtitle(*args, **kwargs)
    Zipper::Subtitle.prepare_subtitle(*args, **kwargs)
  end

  # Prepare subtitles (download, transcribe, translate) and return
  # [vtt_string, language_iso, verbose_json_or_nil]
  def prepare_subtitle
    vtt = nil; lng = nil; tsp = nil

    vtt,lng = fetch_subtitle unless opts.gensubs

    if vtt.nil?
      stl&.update 'transcribing'
      res = Subtitler.transcribe infile
      tsp,lng = res.output, res.lang
      vtt = Subtitler.vtt_convert tsp, word_tags: !opts.nowords
      info.language ||= lng
    end

    if opts.lang && lng && opts.lang.to_s != lng.to_s
      stl&.update 'translating'
      if tsp
        tsp = Subtitler.translate tsp, from: lng, to: opts.lang
        vtt = Subtitler.vtt_convert tsp, word_tags: !opts.nowords
      else
        vtt = Translator.translate_vtt vtt, from: lng, to: opts.lang
      end
      lng = opts.lang
    end

    [vtt, lng, tsp]
  end

  protected

  def reduce_framerate
    return unless opts.nompdecimate
    fgraph << 'mpdecimate'
  end

  def limit_framerate
    # FIXME: conflict with MP4 vsync vfr
    iopts << " -r #{opts.maxfr.to_i}" if opts.maxfr
  end

  def apply_audio_rate
    return unless rate = opts.freq&.to_i || opts.ar&.to_i
    iopts << " -ar #{rate}"
  end

  def apply_audio_channels
    # Workaround for "Channel layout change is not supported"
    # https://www.atlas-informatik.ch/multimediaXpert/Convert.en.html
    iopts << " -ac #{opts.ac.to_i}" if opts.ac
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
    oopts  << " -af atempo=#{opts.speed}"
  end

  def check_width
    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
    # Ensure a sane default width
    opts.width ||= opts.format&.opts&.width || vstrea&.width || 720
    if opts.vf&.index 'transpose'
    elsif vstrea.width < vstrea.height # portrait image
      opts.width /= 2
    end

    # lower resolution
    opts.width = vstrea.width if vstrea.width < opts.width
  end

  def fetch_subtitle
    # scraped subtitles
    if (subs = info&.subtitles).present?
      cads = [opts.lang, :en, subs.keys.first]
      lng,lsub =  cads.each.with_object([]){ |s, r| break r = [s, subs[s]] if subs.key? s }
      return if lng.blank?
      lsub = lsub.find{ |s| s.ext == 'vtt' } || lsub[0]
      sub  = http.get(lsub.url).body
      vtt  = subtitle_to_vtt sub, lsub.ext

    # embedded subtitles
    elsif (esubs = probe.streams.select{ |s| s.codec_type == 'subtitle' }).present?
      esubs.each{ |s| s.lang = ISO_639.find_by_code(s.tags.language).alpha2 }
      index = esubs.index{ |s| opts.lang.in? [s.lang, s.tags.language, s.tags.title] }
      return unless index
      vtt   = extract_vtt index
      lng   = esubs[index].lang
    end

    [vtt, lng]
  end

  # Generate an SRT file from the given media and return its path
  def self.generate_srt(*args, **kwargs)
    Zipper::Subtitle.generate_srt(*args, **kwargs)
  end

  def metadata_args
    (opts.metadata || {}).map{ |k,v| "-metadata #{Sh.escape k}=#{Sh.escape v}" }.join ' '
  end

  def apply_cut
    iopts << " -ss #{opts.ss}" if opts.ss&.match(TIME_REGEX)
    oopts << " -to #{opts.to}" if opts.to&.match(TIME_REGEX)
  end

  def http
    Mechanize.new
  end

end
