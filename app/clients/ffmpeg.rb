class FFmpeg
  MIN_VERSION = Gem::Version.new '9.0'
  BINARIES    = %w[ffmpeg ffprobe].freeze
  TOOLS       = {
    signal:       'ffmpeg astats',
    frame_signal: 'ffmpeg astats metadata',
    loudness:     'ffmpeg ebur128',
    silence:      'ffmpeg silencedetect'
  }.freeze

  PROFILES = {
    encode:    %i[overwrite threads loglevel],
    analysis:  %i[hide_banner no_stats],
    extract:   %i[loglevel overwrite],
    overwrite: %i[overwrite],
    plain:     []
  }.freeze

  STREAMS = {
    audio:    'a',
    video:    'v',
    subtitle: 's',
    data:     'd'
  }.freeze

  VOICE_QUALITY_FILTER = (
    'highpass=f=80,lowpass=f=9000,afftdn=nf=-25,' \
    'acompressor=threshold=-18dB:ratio=2.5:attack=20:release=250,' \
    'dynaudnorm=f=150:g=15,loudnorm=I=-16:TP=-1.5:LRA=11,volume=-2.5dB'
  ).freeze
  SPEECH_CLEANUP_FILTER = 'highpass=f=80'.freeze
  SUBTITLE_CODEC        = 'mov_text'.freeze

  VIDEO_ENCODERS = {
    h264: {
      width:          720,
      quality:        25,
      audio_format:   :aac,
      audio_bitrate:  64,
      percent:        0.99,
      codec_cpu:      'libx264',
      codec_cuda:     'h264_nvenc',
      quality_cpu:    :crf,
      quality_cuda:   :cq,
      preset_cpu:     'fast',
      preset_cuda:    'p4',
      tune_cuda:      'hq',
      aq_cuda:        true,
      bitrate_cuda:   0
    }.freeze,
    h265: {
      width:            720,
      quality:          25,
      audio_format:     :aac,
      audio_bitrate:    64,
      percent:          0.99,
      codec_cpu:        'libx265',
      codec_cuda:       'hevc_nvenc',
      quality_cpu:      :crf,
      quality_cuda:     :cq,
      preset_cpu:       'fast',
      preset_cuda:      'p5',
      tune_cuda:        'hq',
      multipass_cuda:   'qres',
      aq_cuda:          true,
      lookahead_cuda:   32,
      bitrate_cuda:     0
    }.freeze,
    av1: {
      width:         720,
      quality:       50,
      audio_format:  :opus,
      audio_bitrate: 64,
      percent:       0.99,
      codec_cpu:    'libaom-av1',
      codec_cuda:   'av1_nvenc',
      quality_cpu:  :crf,
      quality_cuda: :cq,
      preset_cuda:  'p6'
    }.freeze,
    vp9: {
      width:         720,
      video_bitrate: 835,
      audio_format:  :aac,
      audio_bitrate: 64,
      percent:       0.97,
      codec_cpu:    'libvpx-vp9'
    }.freeze
  }.freeze

  AUDIO_ENCODERS = {
    opus: {
      codec:       'libopus',
      bitrate:     96,
      percent:     0.95,
      channels:    2,
      vbr:         :constrained,
      sample_rate: 48_000
    }.freeze,
    aac: {
      codec:       'aac',
      codec_fdk:   'libfdk_aac',
      profile_fdk: 'aac_he',
      bitrate:     96,
      percent:     0.98
    }.freeze,
    mp3: {
      codec:   'libmp3lame',
      bitrate: 128,
      percent: 0.99,
      abr:     true
    }.freeze
  }.freeze

  METADATA_MARK = 't.me/media_downloader_2bot'.freeze
  CAPABILITY_MUTEX = Mutex.new
  PauseEncoding = Data.define :codec, :profile, :bitrate, :sample_format

  DUB_MIX_BATCH = 100

  # A rendered batch, placed on the timeline like a clip that needs no trimming or tempo change.
  MixedDubClip = Data.define(:path, :start) do
    def speed = 1.0
    def leading = 0.0
    def speech = 0.0
  end

  include Configuration
  include Builder
  include Analysis
  include Operations
  extend Filters
end
