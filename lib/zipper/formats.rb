# frozen_string_literal: true

require 'ostruct'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/class/attribute'

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

    # Original helper moved out of Zipper – kept verbatim for BC.
    def choose_format(type_hash, opts, durat)
      fmt   = opts && opts.format
      fmt ||= if durat && durat >= 10.minutes
                type_hash[:ldefault]
              else
                type_hash[:default]
              end
      fmt   = :aac if Zipper.size_mb_limit && fmt == :opus && durat && durat <= 122
      type_hash[fmt]
    end

end
end
