require 'tempfile'
require_relative 'subtitler/ass'

class Zipper

  class_attribute :size_mb_limit
  self.size_mb_limit = 50

  VID_WIDTH    = 640
  VID_PERCENT  = 0.99

  TIME_REGEX   = /(?:\d?\d:)(?:\d?\d:)\d\d/

  # - Worse quality (better for streaming)
  # - Slower while mining (13x vs 34x on CPU)
  CUDA         = !!ENV['CUDA']
  PRESET       = 'faster'
  H264_PRESET  = if CUDA then 'medium' else PRESET end
  # Use CPU decoding even when encoding with NVENC to avoid incompatibilities with CPU filters.
  H264_OPTS    = ''
  H264_CODEC   = if CUDA then 'h264_nvenc' else 'libx264' end
  H264_QUALITY = if CUDA then 33 else 25 end # to keep similar size
  H265_CODEC   = if CUDA then 'hevc_nvenc' else 'libx265' end
  H265_QFLAG   = if CUDA then '-qp' else '-crf' end
  H265_QUALITY = 25
  H265_PRESET  = if CUDA then 'medium' else PRESET end
  # CUDA-capable AV1 (Ada-generation GPUs) uses NVENC; otherwise fall back to SVT-AV1 (CPU).
  AV1_CODEC    = if CUDA then 'av1_nvenc' else 'libsvtav1' end
  AV1_QFLAG    = if CUDA then '-cq' else '-crf' end
  AV1_PRESET   = if CUDA then '-preset p6' else '' end
  SCALE_KEY    = 'scale'

  VFR_OPTS    = '-vsync vfr'
  VF_SCALE_M2 = "#{SCALE_KEY}=%{width}:trunc(ow/a/2)*2".freeze
  VF_SCALE_M8 = "#{SCALE_KEY}=%{width}:trunc(ow/a/8)*8".freeze

  META_MARK  = '-metadata downloaded_with=t.me/media_downloader_2bot'.freeze
  META_OPTS  = '-map_metadata 0 -id3v2_version 3 -movflags use_metadata_tags -write_id3v1 1'
  META_OPTS << " #{META_MARK} %{metadata}"

  AUDIO_POST_OPTS  = ''
  AUDIO_POST_OPTS << " #{META_OPTS}" unless ENV['SKIP_META']
  VIDEO_POST_OPTS  = '-movflags +faststart'
  VIDEO_POST_OPTS << " #{META_OPTS}" unless ENV['SKIP_META']
  VIDEO_POST_OPTS.freeze

  FDK_AAC = `ffmpeg -encoders 2>/dev/null | grep fdk_aac`.present?

  AUDIO_ENC = SymMash.new(
    opus: {
      percent: 0.95,
      encode:  '-ac 2 -c:a libopus -b:a %{abrate}k'.freeze,
    },
    aac:  {
      percent: 0.98,
      # aac_he_v2 doesn't work with instagram
      encode: if FDK_AAC
              then '-c:a libfdk_aac -profile:a aac_he -b:a %{abrate}k'.freeze
              else '-c:a aac -b:a %{abrate}k'.freeze end
    },
    mp3:  {
      percent: 0.99,
      encode:  '-c:a libmp3lame -abr 1 -b:a %{abrate}k'.freeze,
    },
  )

  THREADS = ENV['THREADS']&.to_i || 16
  FFMPEG  = "ffmpeg -y -threads #{THREADS} -loglevel error"

  FG_SEP      = ','.freeze
  INPUT_LINE  = "-i %{infile} %{iopts} -filter_complex \"#{VF_SCALE_M2}#{FG_SEP}%{fgraph}\" #{VFR_OPTS} %{maps}"
  INPUT8_LINE = "-i %{infile} %{iopts} -filter_complex \"#{VF_SCALE_M8}#{FG_SEP}%{fgraph}\" #{VFR_OPTS} %{maps}"

  Types = SymMash.new(
    video: {
      name:     :video,
      default:  :h264,
      ldefault: :h265,

      h264: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, quality: H264_QUALITY, abrate: 64, acodec: :aac, percent: VID_PERCENT}, #whatsapp can't handle opus in h264
        szopts: "-maxrate:v %{maxrate} -bufsize %{bufsize}",
        cmd: <<-EOC
#{FFMPEG} #{H264_OPTS} #{INPUT_LINE} \
  -c:v #{H264_CODEC} -crf %{quality} -preset #{H264_PRESET} %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      # - SVT-HEVC is discontinued
      # - Performance with ultrafast preset is close to SVT-AV1
      # - Even with much lower CRF, H265 (30 - 21mb) have much lower file size compared to SVT-AV1 (50 - 28mb),
      # which seems to handle better lower resolution and bitrates
      h265: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, quality: H265_QUALITY, abrate: 64, acodec: :aac, percent: VID_PERCENT}, #whatsapp can't handle opus in h265
        szopts: "-maxrate:v %{maxrate}",
        cmd: <<-EOC
#{FFMPEG} #{H264_OPTS} #{INPUT_LINE} \
  -c:v #{H265_CODEC} #{H265_QFLAG} %{quality} -preset #{H265_PRESET} %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      # - MBR reduces quality too much, https://gitlab.com/AOMediaCodec/SVT-AV1/-/issues/2065
      # - Not compatible to upload on Whatsapp Web
      av1: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, quality: 50, abrate: 64, acodec: :opus, percent: VID_PERCENT},
        #szopts: "-svtav1-params mbr=%{maxrate}",
        szopts: '',
        cmd:  <<-EOC
#{FFMPEG} #{H264_OPTS} #{INPUT_LINE} \
  -c:v #{AV1_CODEC} #{AV1_QFLAG} %{quality} #{AV1_PRESET} %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

      # VP9 doesn't seem to respect low bitrates:
      # - it can't control file size in quality mode,
      # - target bitrate mode also not ensuring desired bitrate
      # - SVT-VP9 is discontinued
      vp9: {
        ext:    :mp4,
        mime:   'video/mp4',
        opts:   {width: VID_WIDTH, vbrate: 835, abrate: 64, acodec: :aac, percent: 0.97},
        szopts: "-rc vbr -b:v %{maxrate}",
        cmd:  <<-EOC
#{FFMPEG} #{INPUT8_LINE} \
  -c:v libsvt_vp9 %{szopts} %{acodec} #{VIDEO_POST_OPTS} %{oopts}
        EOC
      },

    },

    audio: {
      name:    :audio,
      default: :opus,

      opus: {
        ext:  :opus,
        mime: 'audio/aac',
        opts: {bitrate: 96, percent: AUDIO_ENC.opus.percent},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{AUDIO_ENC.opus.encode} #{AUDIO_POST_OPTS} %{oopts}"
      },

      aac: {
        ext:  :m4a,
        mime: 'audio/aac',
        opts: {bitrate: 96, percent: AUDIO_ENC.aac.percent},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{AUDIO_ENC.aac.encode} #{AUDIO_POST_OPTS} %{oopts}"
      },

      mp3: {
        ext:  :mp3,
        mime: 'audio/mp3',
        opts: {bitrate: 128, percent: AUDIO_ENC.mp3.percent},
        cmd:  "#{FFMPEG} -vn -i %{infile} %{iopts} #{AUDIO_ENC.mp3.encode} #{AUDIO_POST_OPTS} %{oopts}"
      },
    },
  )

  def self.max_audio_duration br
    1000 * Zipper.size_mb_limit / (br.to_i / 8) / 60
  end

  VID_DURATION_THLD = -> { size_mb_limit ? 20 : Float::INFINITY }
  AUD_DURATION_THLD = -> { size_mb_limit ? max_audio_duration(Types.audio.opus.opts.bitrate) : Float::INFINITY }

  # reduce width for every minutes interval exceeding VID_DURATION_THLD
  VID_WIDTH_REDUC = SymMash.new width: 80, minutes: 8
  AUD_BRATE_REDUC = SymMash.new brate:  8, minutes: 8

  def self.zip_video *args, **params
    self.new(*args, **params).zip_video
  end
  def self.zip_audio *args, **params
    self.new(*args, **params).zip_audio
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
    @probe   = probe || Prober.for(infile)
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
    opts.quality = opts.quality&.to_i
    opts.abrate  = opts.abrate&.to_i

    @duration    = probe.format.duration.to_f / opts.speed

  end

  def video?; @type == :video; end
  def audio?; @type == :audio; end

  def zip_video
    @type = :video

    # Ensure the NVENC encoder receives frames in a supported pixel format
    # add it early so it comes right after the scale* filter and before any
    # other dynamically-added filters, avoiding a dangling comma when no
    # other filters are present.
    fgraph << 'format=yuv420p' if CUDA && !fgraph.include?('format=yuv420p')
    check_width
    reduce_framerate
    limit_framerate
    apply_audio_rate
    apply_audio_channels

    apply_subtitle
    apply_speed
    apply_cut
    szopts = apply_video_size_limits

    aenc   = AUDIO_ENC[opts.acodec&.to_sym] || AUDIO_ENC.opus
    opts.abrate = (aenc.percent * opts.abrate).round if size_mb_limit
    acodec = aenc.encode % {abrate: opts.abrate}

    cmd = opts.format.cmd % {
      infile:   Sh.escape(infile),
      iopts:    iopts,
      fgraph:   fgraph.join(FG_SEP),
      maps:     maps.map{ |m| "-map #{m}" }.join(' '),
      oopts:    oopts,
      width:    opts.width,
      quality:  opts.quality,
      acodec:   acodec,
      vbrate:   opts.vbrate,
      szopts:   szopts,
      metadata: metadata_args,
    }

    cmd.strip!
    cmd << " #{Sh.escape outfile}"
    Sh.run cmd
  end

  def zip_audio
    @type = :audio

    apply_audio_rate
    apply_audio_channels

    apply_speed
    apply_audio_size_limit
    apply_cut

    cmd = opts.format.cmd % {
      infile:   Sh.escape(infile),
      iopts:    iopts,
      oopts:    oopts,
      abrate:   opts.bitrate,
      metadata: metadata_args,
    }

    cmd.strip!
    cmd << " #{Sh.escape outfile}"
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
    wpath = 'audio.wav'

    cmd = ['ffmpeg', '-i', Sh.escape(path), '-y', Sh.escape(wpath)].join(' ')
    _, _, st = Sh.run cmd
    raise 'ffmpeg failed' unless st.success?

    wpath
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
    return unless size_mb_limit

    opts.bitrate = (opts.percent * 8*size_mb_limit*1000).to_f / duration if self.class.max_audio_duration(opts.bitrate) < duration / 60
  end

  def apply_video_size_limits
    return unless size_mb_limit
    return if opts.custom_width

    minutes  = (duration / 60).ceil
    vthld    = self.class.vid_duration_thld

    # reduce resolution
    if minutes > vthld and opts.width > dopts.width/3
      reduc,intv  = VID_WIDTH_REDUC.values_at :width, :minutes
      opts.width -= reduc * ((minutes - vthld).to_f / intv).ceil
      opts.width  = dopts.width/3 if opts.width < dopts.width/3
      opts.width -= 1 if opts.width % 2 == 1
    end
    # reduce audio bitrate
    if minutes > vthld and opts.abrate > dopts.abrate/2
      reduc,intv   = AUD_BRATE_REDUC.values_at :brate, :minutes
      opts.abrate -= reduc * ((minutes - vthld).to_f / intv).ceil
      opts.abrate  = dopts.abrate/2 if opts.abrate < dopts.abrate/2
    end

    audsize  = (duration * opts.abrate.to_f/8) / 1000
    vidsize  = (size_mb_limit - audsize).to_i
    bufsize  = "#{vidsize}M"

    maxrate  = (8*(opts.percent * vidsize * 1000) / duration).to_i
    maxrate  = opts.vbrate if opts.vbrate and maxrate > opts.vbrate
    maxrate  = "#{maxrate}k"

    opts.format.szopts % {maxrate:, bufsize:}
  end

  def apply_speed
    return if opts.speed == 1

    fgraph << "setpts=PTS/#{opts.speed}" if video?
    #iopts  << " -t #{duration}" # attached subtitle mess with the length of the video
    oopts  << " -af atempo=#{opts.speed}"
  end

  def check_width
    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
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
      lsub = lsub.find{ |s| s.ext == 'vtt' } || lsubs[0]
      sub  = http.get(lsub.url).body
      vtt  = subtitle_to_vtt sub, lsub.ext

    # embedded subtitles
    elsif (esubs = probe.streams.select{ |s| s.codec_type == 'subtitle' }).present?
      esubs.each{ |s| s.lang = ISO_639.find_by_code(s.tags.language).alpha2 }
      index = esubs.index{ |s| opts.lang.in? [s.lang, s.tags.language, s.tags.title] }
      return unless index
      vtt   = extract_vtt index
      lng   = esubs[index].lang
      opts.lang = lng
    end

    [vtt, lng]
  end

  def apply_subtitle
    return if !opts.lang and !opts.subs

    vtt,lng = fetch_subtitle if !opts.gensubs and opts.lang

    if !vtt
      stl&.update 'transcribing'
      res = Subtitler.transcribe infile
      tsp,lng = res.output, res.lang
      info.language ||= lng # instagram doesn't have language metadata
    end

    if opts.lang and opts.lang != lng
      stl&.update 'translating'
      if tsp
        tsp = Subtitler.translate tsp, from: lng, to: opts.lang
        vtt = Subtitler.vtt_convert tsp
      else
        vtt = Translator.translate_vtt vtt, from: lng, to: opts.lang
      end

      lng = opts.lang
    else
      vtt = Subtitler.vtt_convert tsp
    end
    stl&.update 'transcoding'

    # generate ASS subtitle directly (scales font automatically for portrait videos)
    vstrea = probe.streams.find{ |s| s.codec_type == 'video' }
    is_portrait = vstrea.width < vstrea.height
    ass_content = Subtitler::Ass.from_vtt(vtt, portrait: is_portrait, mode: :instagram)

    assp = 'sub.ass'
    File.write assp, ass_content
    fgraph << "ass=#{assp}"

    # Write VTT for embedding
    subp = 'sub.vtt'
    File.write subp, vtt
    iopts << " -i #{subp}"
    # embed subtitle track if speed not changed (timestamps stay aligned)
    oopts << " -c:s mov_text -metadata:s:s:0 language=#{lng} -metadata:s:s:0 title=#{lng}" if opts.speed == 1
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

  # Dynamic helpers that reevaluate the thresholds at runtime
  def self.vid_duration_thld
    size_mb_limit ? 20 : Float::INFINITY
  end

  def self.aud_duration_thld
    size_mb_limit ? max_audio_duration(Types.audio.opus.opts.bitrate) : Float::INFINITY
  end

end
