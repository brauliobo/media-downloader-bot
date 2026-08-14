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
      channels:    1,
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

  def self.verify! runner: Sh.method(:run)
    new(runner: runner).verify!
  end

  def self.pause_encoding format, fdk_aac: nil
    format = format ? format.to_h.transform_keys(&:to_sym) : {}
    codec_name = format[:codec_name].to_s
    return PauseEncoding.new codec: nil, profile: nil, bitrate: nil, sample_format: nil if codec_name.empty?

    encoder = pause_codec codec_name, format, fdk_aac
    return PauseEncoding.new codec: nil, profile: nil, bitrate: nil, sample_format: nil unless encoder

    PauseEncoding.new(
      codec:        encoder,
      profile:      pause_profile(codec_name, format),
      bitrate:      pause_bitrate(codec_name, format, encoder),
      sample_format: pause_sample_format(codec_name, format)
    )
  end

  def self.transcription_binary
    ENV.fetch 'TRANSCRIBE_CPP_FFMPEG', BINARIES.first
  end

  def self.fdk_aac_available? ffmpeg: BINARIES[0], runner: Sh.method(:run)
    @fdk_aac_capabilities ||= {}
    key = [ffmpeg, runner]
    CAPABILITY_MUTEX.synchronize do
      return @fdk_aac_capabilities[key] if @fdk_aac_capabilities.key? key

      detector = new ffmpeg: ffmpeg, runner: runner
      @fdk_aac_capabilities[key] = detector.encoder_available? 'libfdk_aac'
    end
  end

  def self.pause_codec codec_name, format, fdk_aac
    return {'mp3' => 'libmp3lame', 'opus' => 'libopus', 'vorbis' => 'libvorbis'}[codec_name] if
      %w[mp3 opus vorbis].include? codec_name

    return codec_name unless codec_name == 'aac'

    fdk_aac = fdk_aac_available? if fdk_aac.nil?
    return if !fdk_aac && format[:profile].to_s.match?(/HE-AAC/i)

    fdk_aac ? AUDIO_ENCODERS.fetch(:aac).fetch(:codec_fdk) : AUDIO_ENCODERS.fetch(:aac).fetch(:codec)
  end

  def self.pause_profile codec_name, format
    return unless codec_name == 'aac'

    {
      'LC'       => 'aac_low',
      'HE-AAC'   => 'aac_he',
      'HE-AACV2' => 'aac_he_v2',
    }[format[:profile].to_s.upcase]
  end

  def self.pause_bitrate codec_name, format, encoder
    bit_rate = format[:bit_rate].to_i
    return unless bit_rate.positive?
    return if codec_name.start_with?('pcm_') || codec_name == 'flac'

    bit_rate if encoder
  end

  def self.pause_sample_format codec_name, format
    return unless codec_name.start_with? 'pcm_'

    format[:sample_fmt].to_s unless format[:sample_fmt].to_s.empty?
  end

  private_class_method :pause_codec, :pause_profile, :pause_bitrate, :pause_sample_format

  def initialize ffmpeg: BINARIES[0], ffprobe: BINARIES[1], runner: Sh.method(:run),
                  threads: ENV['THREADS'] || 16, profile: :encode, fdk_aac: false
    @ffmpeg          = ffmpeg
    @ffprobe         = ffprobe
    @runner          = runner
    @default_threads = threads
    @profile         = profile.to_sym
    @fdk_aac         = fdk_aac
    PROFILES.fetch @profile
    reset!
  end

  def verify!
    one_shot do
      [@ffmpeg, @ffprobe].each do |binary|
        name = File.basename binary
        stdout, stderr, status = @runner.call [binary, '-version']
        output = "#{stdout}\n#{stderr}"
        raise "#{name} is required" unless status.success?

        version = output[/\A#{Regexp.escape name} version n?(\d+(?:\.\d+)+)/, 1]
        raise "unable to determine #{name} version" unless version
        next if Gem::Version.new(version) >= MIN_VERSION

        raise "#{name} #{MIN_VERSION} or newer is required; found #{version}"
      rescue Errno::ENOENT
        raise "#{name} is required"
      end
    end
  end
end
