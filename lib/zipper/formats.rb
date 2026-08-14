# frozen_string_literal: true

require_relative '../ffmpeg'

class Zipper
  module Formats
    VIDEO_PROFILES = FFmpeg::VIDEO_ENCODERS
    AUDIO_PROFILES = FFmpeg::AUDIO_ENCODERS
    FDK_AAC        = FFmpeg.fdk_aac_available?

    AUDIO_ENC = SymMash.new(
      opus: {
        percent: AUDIO_PROFILES.fetch(:opus).fetch(:percent),
        encode:  '-ac 1 -ar 48000 -c:a libopus -b:a %{abrate}k'.freeze
      },
      aac:  {
        percent: AUDIO_PROFILES.fetch(:aac).fetch(:percent),
        encode:  if FDK_AAC
                   '-c:a libfdk_aac -profile:a aac_he -b:a %{abrate}k'.freeze
                 else
                   '-c:a aac -b:a %{abrate}k'.freeze
                 end
      },
      mp3:  {
        percent: AUDIO_PROFILES.fetch(:mp3).fetch(:percent),
        encode:  '-c:a libmp3lame -abr 1 -b:a %{abrate}k'.freeze
      }
    )

    def self.video_options format
      profile = VIDEO_PROFILES.fetch format.to_sym
      {
        width:   profile.fetch(:width),
        quality: profile[:quality],
        vbrate:  profile[:video_bitrate],
        abrate:  profile.fetch(:audio_bitrate),
        acodec:  profile.fetch(:audio_format),
        percent: profile.fetch(:percent),
      }.compact
    end

    def self.audio_options format
      profile = AUDIO_PROFILES.fetch format.to_sym
      {bitrate: profile.fetch(:bitrate), percent: profile.fetch(:percent)}
    end

    def self.video_encoder_options format
      profile = VIDEO_PROFILES.fetch format.to_sym
      extra_cuda = cuda_options profile
      extra_cuda = "-preset #{profile[:preset_cuda]}" if extra_cuda.empty? && profile[:preset_cuda]
      {
        codec_cpu:   profile.fetch(:codec_cpu),
        codec_cuda:  profile[:codec_cuda],
        qflag_cpu:   profile[:quality_cpu] ? "-#{profile[:quality_cpu]}" : '',
        qflag_cuda:  profile[:quality_cuda] && "-#{profile[:quality_cuda]}",
        preset_cpu:  profile[:preset_cpu],
        preset_cuda: profile[:preset_cuda],
        extra_cuda:  extra_cuda
      }.compact
    end

    def self.cuda_options profile
      options = []
      options.concat ['-tune', profile[:tune_cuda]] if profile[:tune_cuda]
      options.concat ['-multipass', profile[:multipass_cuda]] if profile[:multipass_cuda]
      options.concat ['-spatial-aq', '1', '-temporal-aq', '1'] if profile[:aq_cuda]
      options.concat ['-rc-lookahead', profile[:lookahead_cuda].to_s] if profile[:lookahead_cuda]
      options.concat ['-b:v', profile[:bitrate_cuda].to_s] if profile.key? :bitrate_cuda
      options.join ' '
    end

    TYPES = SymMash.new(
      video: {
        name:     :video,
        default:  :h264,
        ldefault: :h265,
        h264:     {
          ext:  :mp4,
          mime: 'video/mp4',
          opts: video_options(:h264),
          **video_encoder_options(:h264)
        },
        h265:     {
          ext:  :mp4,
          mime: 'video/mp4',
          opts: video_options(:h265),
          **video_encoder_options(:h265)
        },
        av1:      {
          ext:  :mp4,
          mime: 'video/mp4',
          opts: video_options(:av1),
          **video_encoder_options(:av1)
        },
        vp9:      {
          ext:  :mp4,
          mime: 'video/mp4',
          opts: video_options(:vp9),
          **video_encoder_options(:vp9)
        }
      },
      audio: {
        name:    :audio,
        default: :opus,
        opus:    {
          ext:  :opus,
          mime: 'audio/ogg',
          opts: audio_options(:opus),
          encode: AUDIO_ENC.opus.encode
        },
        aac:     {
          ext:  :m4a,
          mime: 'audio/aac',
          opts: audio_options(:aac),
          encode: AUDIO_ENC.aac.encode
        },
        mp3:     {
          ext:  :mp3,
          mime: 'audio/mp3',
          opts: audio_options(:mp3),
          encode: AUDIO_ENC.mp3.encode
        }
      }
    )

    def self.cuda? opts = nil
      cuda_encode?(opts) || cuda_decode?(opts)
    end

    def self.cuda_encode? opts = nil
      return false if opts&.nocuda

      !!(opts&.cuda || opts&.cudaenc || ENV['CUDA'] || ENV['CUDAENC'])
    end

    def self.cuda_decode? opts = nil
      return false if opts&.nocuda

      !!(opts&.cuda || opts&.cudadec || ENV['CUDA'] || ENV['CUDADEC'])
    end

    def self.default_width size_mb_limit
      return 1920 if size_mb_limit.nil? || size_mb_limit > 500
      return 1080 if size_mb_limit > 50

      720
    end

    def self.choose_format type_hash, opts, durat
      fmt = opts && opts.format
      return fmt if fmt.respond_to? :mime

      fmt = fmt.to_sym if fmt.is_a? String
      fmt = nil unless fmt.is_a? Symbol

      kind = (type_hash[:name] || type_hash['name']).to_s
      if fmt
        if kind == 'video'
          fmt = :h264 if fmt.in? %i[mp4 x264 h.264]
          fmt = :h265 if fmt.in? %i[hevc x265 h.265]
          fmt = :vp9 if fmt == :webm
        elsif kind == 'audio'
          fmt = :aac if fmt == :m4a
          fmt = :opus if fmt == :ogg
        end
      end

      default      = type_hash[:default] || type_hash['default']
      long_default = type_hash[:ldefault] || type_hash['ldefault']
      use_long_default = kind == 'video' && durat && durat >= 10.minutes && long_default && cuda?(opts)
      fmt ||= use_long_default ? long_default : default
      fmt = :aac if Zipper.size_mb_limit && fmt == :opus && durat && durat <= 122
      chosen = type_hash[fmt] || type_hash[fmt.to_s]
      return chosen if chosen

      fmt = use_long_default ? long_default : default
      type_hash[fmt] || type_hash[fmt.to_s]
    end
  end
end
