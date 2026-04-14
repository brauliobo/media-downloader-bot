# frozen_string_literal: true

require 'ostruct'

class Zipper
  # Collection of codec definitions, encoder templates and helpers that are
  # purely data-oriented.  No business logic that touches files should live
  # here – that stays in the caller (e.g. Zipper itself or the future
  # Pipelines).
  module Formats
    VID_WIDTH   = 720
    VID_PERCENT = 0.99

    # Detect external ffmpeg encoder availability.  Needs to be evaluated once
    # at process boot time; we memoise via constant.
    FDK_AAC = `ffmpeg -encoders 2>/dev/null | grep fdk_aac`.present?

    # Audio encoder templates together with the coefficient that is used later
    # for size calculations (see Limits module).
    AUDIO_ENC = SymMash.new(
      opus: {
        percent: 0.95,
        encode:  '-ac 1 -ar 48000 -c:a libopus -b:a %{abrate}k'.freeze,
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

    # Codec / container matrix for both audio and video.
    TYPES = SymMash.new(
      video: {
        name:     :video,
        default:  :h264,
        ldefault: :h265,

        h264: {
          ext:    :mp4,
          mime:   'video/mp4',
          opts:   {width: VID_WIDTH, quality: 25, abrate: 64, acodec: :aac, percent: VID_PERCENT},
          szopts_cpu:  '-maxrate:v %{maxrate} -bufsize %{bufsize}',
          szopts_cuda: '',
          codec_cpu:  'libx264',
          codec_cuda: 'h264_nvenc',
          qflag_cpu:  '-crf',
          qflag_cuda: '-crf',
        },

        h265: {
          ext:    :mp4,
          mime:   'video/mp4',
          opts:   {width: VID_WIDTH, quality: 25, abrate: 64, acodec: :aac, percent: VID_PERCENT},
          szopts_cpu:  '-maxrate:v %{maxrate}',
          szopts_cuda: '-rc:v vbr',
          codec_cpu:  'libx265',
          codec_cuda: 'hevc_nvenc',
          qflag_cpu:  '-crf',
          qflag_cuda: '-cq',
        },

        av1: {
          ext:    :mp4,
          mime:   'video/mp4',
          opts:   {width: VID_WIDTH, quality: 50, abrate: 64, acodec: :opus, percent: VID_PERCENT},
          szopts: '',
          codec_cpu:  'libsvtav1',
          codec_cuda: 'av1_nvenc',
          qflag_cpu:  '-crf',
          qflag_cuda: '-cq',
          extra_cuda: '-preset p6',
        },

        vp9: {
          ext:    :mp4,
          mime:   'video/mp4',
          opts:   {width: VID_WIDTH, vbrate: 835, abrate: 64, acodec: :aac, percent: 0.97},
          szopts: '-rc vbr -b:v %{maxrate}',
          codec_cpu:  'libsvt_vp9',
          qflag_cpu:  '',
        },
      },

      audio: {
        name:    :audio,
        default: :opus,

        opus: {
          ext:    :opus,
          mime:   'audio/ogg',
          opts:   {bitrate: 96, percent: AUDIO_ENC.opus.percent},
          encode: AUDIO_ENC.opus.encode,
        },

        aac: {
          ext:    :m4a,
          mime:   'audio/aac',
          opts:   {bitrate: 96, percent: AUDIO_ENC.aac.percent},
          encode: AUDIO_ENC.aac.encode,
        },

        mp3: {
          ext:    :mp3,
          mime:   'audio/mp3',
          opts:   {bitrate: 128, percent: AUDIO_ENC.mp3.percent},
          encode: AUDIO_ENC.mp3.encode,
        },
      },
    )

    module_function

    def default_width(size_mb_limit)
      return 1920 if size_mb_limit.nil? || size_mb_limit > 500
      return 1080 if size_mb_limit > 50
      720
    end

    # Original helper moved out of Zipper – kept verbatim for BC.
    def choose_format(type_hash, opts, durat)
      fmt = opts && opts.format

      # allow callers to pass the already-resolved spec
      return fmt if fmt.respond_to?(:mime)

      # Only accept user-provided format selectors as String/Symbol.
      # Any other truthy value (e.g. {}, 1) is treated as "no format specified".
      fmt = fmt.to_sym if fmt.is_a?(String)
      fmt = nil unless fmt.is_a?(Symbol)

      # Accept common container/alias names and map them to internal codec keys.
      # Users often pass extensions (mp4/m4a) rather than codec identifiers.
      if fmt
        kind = (type_hash[:name] || type_hash['name']).to_s
        if kind == 'video'
          fmt = :h264 if fmt.in?(%i[mp4 x264 h.264])
          fmt = :h265 if fmt.in?(%i[hevc x265 h.265])
          fmt = :vp9  if fmt == :webm
        elsif kind == 'audio'
          fmt = :aac  if fmt == :m4a
          fmt = :opus if fmt == :ogg
        end
      end

      defk  = type_hash[:default]  || type_hash['default']
      ldefk = type_hash[:ldefault] || type_hash['ldefault']
      fmt ||= (durat && durat >= 10.minutes) ? ldefk : defk
      fmt   = :aac if Zipper.size_mb_limit && fmt == :opus && durat && durat <= 122
      chosen = type_hash[fmt] || type_hash[fmt.to_s]
      return chosen if chosen

      # Unknown user-provided fmt: fall back to defaults instead of returning nil.
      fmt = (durat && durat >= 10.minutes) ? ldefk : defk
      type_hash[fmt] || type_hash[fmt.to_s]
    end

end
end
